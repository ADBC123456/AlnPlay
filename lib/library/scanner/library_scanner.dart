import 'dart:async';
import 'dart:collection';

import '../models/library_models.dart';
import '../repository/library_repository.dart';
import '../source/strm_file.dart';

enum ScanState { queued, scanning, partial, complete, failed, cancelled }

class ScanProgress {
  const ScanProgress({
    required this.rootId,
    required this.state,
    required this.discoveredFiles,
    this.error,
  });

  final String rootId;
  final ScanState state;
  final int discoveredFiles;
  final Object? error;
}

abstract interface class LibraryScanner {
  Stream<ScanProgress> get progress;

  Future<void> refreshRoots(List<LibraryRoot> roots);

  void cancel(String scanId);
}

class CoordinatedLibraryScanner implements LibraryScanner {
  CoordinatedLibraryScanner({
    required this.repository,
    required Iterable<LibrarySourceAdapter> adapters,
    required this.metadataResolver,
    DateTime Function()? clock,
  }) : _adapters = {for (final adapter in adapters) adapter.sourceId: adapter},
       _clock = clock ?? DateTime.now;

  static const int batchSize = 100;
  static const Duration batchInterval = Duration(seconds: 1);
  static const Duration listingTimeout = Duration(seconds: 30);
  static const Duration smallTextTimeout = Duration(seconds: 10);

  final LibraryRepository repository;
  final Map<String, LibrarySourceAdapter> _adapters;
  final MetadataResolver metadataResolver;
  final DateTime Function() _clock;
  final StreamController<ScanProgress> _progress =
      StreamController<ScanProgress>.broadcast();
  final Set<String> _cancelled = {};
  int _generationCounter = 0;

  @override
  Stream<ScanProgress> get progress => _progress.stream;

  @override
  Future<void> refreshRoots(List<LibraryRoot> roots) async {
    final grouped = <String, List<LibraryRoot>>{};
    for (final root in roots) {
      (grouped[root.sourceId] ??= []).add(root);
      _progress.add(
        ScanProgress(
          rootId: root.id,
          state: ScanState.queued,
          discoveredFiles: 0,
        ),
      );
    }
    final groups = Queue<List<LibraryRoot>>.of(grouped.values);
    final workers = <Future<void>>[];
    final workerCount = groups.length < 2 ? groups.length : 2;
    for (var i = 0; i < workerCount; i++) {
      workers.add(_runSourceGroups(groups));
    }
    await Future.wait(workers);
  }

  Future<void> _runSourceGroups(Queue<List<LibraryRoot>> groups) async {
    while (groups.isNotEmpty) {
      final roots = groups.removeFirst();
      // Roots for one source stay sequential so native clients do not receive
      // overlapping directory requests for the same authenticated server.
      for (final root in roots) {
        await _refreshRoot(root);
      }
    }
  }

  Future<void> _refreshRoot(LibraryRoot root) async {
    final adapter = _adapters[root.sourceId];
    final generation =
        '${_clock().microsecondsSinceEpoch}:${_generationCounter++}';
    if (adapter == null) {
      _progress.add(
        ScanProgress(
          rootId: root.id,
          state: ScanState.failed,
          discoveredFiles: 0,
          error: StateError('No adapter for source ${root.sourceId}'),
        ),
      );
      return;
    }
    _cancelled.remove(root.id);
    await repository.applyScanBatch(
      ScanBatch(rootId: root.id, generation: generation, isStart: true),
    );
    _progress.add(
      ScanProgress(
        rootId: root.id,
        state: ScanState.scanning,
        discoveredFiles: 0,
      ),
    );

    final queue = Queue<_QueuedDirectory>()
      ..add(_QueuedDirectory(root.directory, const [], 0));
    final visited = <String>{};
    final seen = <String>{};
    final staged = <MatchResult>[];
    final identifying = <Future<void>>[];
    var lastFlush = _clock();
    var isPartial = false;
    Object? partialError;
    var acceptingMetadata = true;

    Future<void> flush() async {
      if (staged.isEmpty) return;
      final ready = List<MatchResult>.of(staged);
      staged.clear();
      await repository.applyScanBatch(
        ScanBatch(
          rootId: root.id,
          generation: generation,
          files: [for (final result in ready) result.file],
          titles: [
            for (final result in ready)
              if (result.title != null) result.title!,
          ],
          episodes: [
            for (final result in ready)
              if (result.episode != null) result.episode!,
          ],
        ),
      );
      lastFlush = _clock();
    }

    try {
      while (queue.isNotEmpty) {
        _checkCancelled(root.id);
        final queued = queue.removeFirst();
        final canonical = _canonicalDirectory(queued.directory);
        if (!visited.add(canonical)) continue;
        String? cursor;
        final seenCursors = <String>{};
        do {
          _checkCancelled(root.id);
          ListingPage page;
          try {
            page = await adapter
                .list(queued.directory, cursor: cursor)
                .timeout(listingTimeout);
          } catch (error) {
            if (queued.depth == 0 && seen.isEmpty) rethrow;
            isPartial = true;
            partialError ??= error;
            break;
          }
          for (final entry in page.entries) {
            _checkCancelled(root.id);
            if (entry.isDirectory) {
              if (entry.directory != null) {
                if (queued.depth >= root.maxScanDepth) {
                  isPartial = true;
                  partialError ??= StateError(
                    'Scan depth limit ${root.maxScanDepth} reached',
                  );
                } else {
                  queue.add(
                    _QueuedDirectory(entry.directory!, [
                      ...queued.ancestors,
                      if ((queued.directory.contextName ?? '').isNotEmpty)
                        queued.directory.contextName!,
                    ], queued.depth + 1),
                  );
                }
              }
              continue;
            }
            final sourceRef = entry.sourceRef;
            if (sourceRef == null || !_isSupportedMedia(entry.name)) continue;
            final file = MediaFile(
              id: entry.stableId,
              rootIds: {root.id},
              sourceRef: sourceRef,
              originalFileName: entry.name,
              sizeBytes: entry.sizeBytes,
              modifiedAt: entry.modifiedAt,
              discoveredAt: _clock(),
              titleId: entry.serverTitleId,
              episodeId:
                  entry.serverTitleId != null && entry.episodeNumber != null
                  ? '${entry.serverTitleId}:s${entry.seasonNumber ?? 'unknown'}'
                        ':e${entry.episodeNumber}'
                  : null,
              matchOrigin: entry.serverTitleId == null
                  ? null
                  : MatchOrigin.server,
              availability: MediaAvailability.available,
              legacyResumeKey: entry.legacyResumeKey ?? entry.stableId,
              isStrm: entry.isStrm || isStrmFileName(entry.name),
            );
            seen.add(file.id);
            // Persist discovery before optional STRM validation and metadata.
            staged.add(MatchResult(file: file));
            if (file.isStrm) {
              final SmallTextLibrarySourceAdapter? reader =
                  adapter is SmallTextLibrarySourceAdapter
                  ? adapter as SmallTextLibrarySourceAdapter
                  : null;
              try {
                if (reader == null) {
                  throw StateError('Source does not support STRM text reads');
                }
                parseExternalStrm(
                  await reader.readSmallText(file).timeout(smallTextTimeout) ??
                      '',
                );
              } catch (error) {
                isPartial = true;
                partialError ??= error;
                staged.add(
                  MatchResult(
                    file: file.copyWith(
                      identificationState: MetadataState.failed,
                    ),
                  ),
                );
                continue;
              }
            }
            final context = DiscoveryContext(
              rootId: root.id,
              directoryNames: List.unmodifiable([
                ...queued.ancestors,
                if ((queued.directory.contextName ?? '').isNotEmpty)
                  queued.directory.contextName!,
              ]),
            );
            final task = metadataResolver.resolve(file, context).then((
              result,
            ) async {
              if (!acceptingMetadata || _cancelled.contains(root.id)) return;
              staged.add(result);
              if (staged.length >= batchSize ||
                  _clock().difference(lastFlush) >= batchInterval) {
                await flush();
              }
            });
            identifying.add(task);
            if (identifying.length >= 32) {
              await Future.wait(identifying);
              identifying.clear();
              _checkCancelled(root.id);
            }
            _progress.add(
              ScanProgress(
                rootId: root.id,
                state: ScanState.scanning,
                discoveredFiles: seen.length,
              ),
            );
          }
          cursor = page.nextCursor;
          if (cursor != null && cursor.isNotEmpty && !seenCursors.add(cursor)) {
            isPartial = true;
            partialError ??= StateError('Source returned a repeated cursor');
            break;
          }
        } while (cursor != null && cursor.isNotEmpty);
      }
      await flush();
      await Future.wait(identifying);
      await flush();
      _checkCancelled(root.id);
      if (!isPartial) {
        await repository.applyScanBatch(
          ScanBatch(
            rootId: root.id,
            generation: generation,
            isRootComplete: true,
            seenFileIds: seen,
          ),
        );
      }
      _progress.add(
        ScanProgress(
          rootId: root.id,
          state: isPartial ? ScanState.partial : ScanState.complete,
          discoveredFiles: seen.length,
          error: partialError,
        ),
      );
    } on _ScanCancelled {
      acceptingMetadata = false;
      _progress.add(
        ScanProgress(
          rootId: root.id,
          state: ScanState.cancelled,
          discoveredFiles: seen.length,
        ),
      );
    } catch (error) {
      acceptingMetadata = false;
      // No completion batch means old records are retained for this root.
      _progress.add(
        ScanProgress(
          rootId: root.id,
          state: ScanState.failed,
          discoveredFiles: seen.length,
          error: error,
        ),
      );
    }
  }

  @override
  void cancel(String scanId) => _cancelled.add(scanId);

  void _checkCancelled(String rootId) {
    if (_cancelled.contains(rootId)) throw const _ScanCancelled();
  }

  static String _canonicalDirectory(SourceDirectory directory) =>
      '${directory.sourceId}:${directory.identity.replaceAll('\\', '/')}';

  static bool _isSupportedMedia(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return const {
      'mkv',
      'mp4',
      'm4v',
      'mov',
      'avi',
      'webm',
      'wmv',
      'flv',
      'ogv',
      'rmvb',
      'mpg',
      'mpeg',
      'vob',
      'ts',
      'm2ts',
      'mts',
      'strm',
    }.contains(name.substring(dot + 1).toLowerCase());
  }
}

class _QueuedDirectory {
  const _QueuedDirectory(this.directory, this.ancestors, this.depth);

  final SourceDirectory directory;
  final List<String> ancestors;
  final int depth;
}

class _ScanCancelled implements Exception {
  const _ScanCancelled();
}

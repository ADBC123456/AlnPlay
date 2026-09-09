import 'dart:async';
import 'dart:io';

import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/repository/library_repository.dart';
import 'package:dream_player/library/scanner/library_scanner.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late JsonLibraryRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dream_scanner_test_');
    repository = JsonLibraryRepository(storageDirectory: directory);
  });

  tearDown(() async {
    await repository.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'recurses to the configured depth, follows pages, and breaks loops',
    () async {
      final adapter = _FakeAdapter(
        sourceId: 'source:a',
        pages: {
          'root|': ListingPage(
            entries: [_directoryEntry('child'), _videoEntry('a.mkv')],
            nextCursor: 'page-2',
          ),
          'root|page-2': ListingPage(
            entries: [
              _directoryEntry('root', identity: 'root'),
              _videoEntry('b.mp4'),
            ],
          ),
          'child|': ListingPage(entries: [_videoEntry('c.m2ts')]),
        },
      );
      final scanner = CoordinatedLibraryScanner(
        repository: repository,
        adapters: [adapter],
        metadataResolver: const _PassthroughResolver(),
      );
      final states = <ScanState>[];
      final subscription = scanner.progress.listen(
        (event) => states.add(event.state),
      );

      await scanner.refreshRoots([_root('root-id', adapter.sourceId)]);
      final data = await repository.snapshot();
      expect(data.files.keys, {
        'source:a:a.mkv',
        'source:a:b.mp4',
        'source:a:c.m2ts',
      });
      expect(
        adapter.calls.where((call) => call.startsWith('root|')),
        hasLength(2),
      );
      expect(
        states,
        containsAllInOrder([
          ScanState.queued,
          ScanState.scanning,
          ScanState.complete,
        ]),
      );
      await subscription.cancel();
    },
  );

  test('depth-limited scan is partial and keeps unseen old files', () async {
    await repository.applyScanBatch(
      const ScanBatch(rootId: 'root-id', generation: 'seed', isStart: true),
    );
    await repository.applyScanBatch(
      ScanBatch(
        rootId: 'root-id',
        generation: 'seed',
        files: [_indexedFile('source:a:old.mkv')],
      ),
    );
    final adapter = _FakeAdapter(
      sourceId: 'source:a',
      pages: {
        'root|': ListingPage(entries: [_directoryEntry('level-1')]),
        'level-1|': ListingPage(entries: [_directoryEntry('level-2')]),
      },
    );
    final scanner = CoordinatedLibraryScanner(
      repository: repository,
      adapters: [adapter],
      metadataResolver: const _PassthroughResolver(),
    );
    final partial = Completer<ScanProgress>();
    final subscription = scanner.progress.listen((event) {
      if (event.state == ScanState.partial && !partial.isCompleted) {
        partial.complete(event);
      }
    });

    await scanner.refreshRoots([
      LibraryRoot(
        id: 'root-id',
        sourceId: adapter.sourceId,
        displayName: 'root',
        maxScanDepth: 1,
        directory: const SourceDirectory(
          sourceId: 'source:a',
          sourceType: 'test',
          identity: 'root',
          path: 'root',
        ),
      ),
    ]);
    expect((await partial.future).error, isNotNull);
    expect(
      (await repository.snapshot()).files['source:a:old.mkv']!.availability,
      MediaAvailability.available,
    );
    expect(adapter.calls, isNot(contains('level-2|')));
    await subscription.cancel();
  });

  test(
    'ignores unsupported files and preserves old data on source failure',
    () async {
      await repository.applyScanBatch(
        const ScanBatch(rootId: 'root-id', generation: 'seed', isStart: true),
      );
      await repository.applyScanBatch(
        ScanBatch(
          rootId: 'root-id',
          generation: 'seed',
          files: [_indexedFile('source:a:old.mkv')],
        ),
      );
      await repository.applyScanBatch(
        const ScanBatch(
          rootId: 'root-id',
          generation: 'seed',
          isRootComplete: true,
          seenFileIds: {'source:a:old.mkv'},
        ),
      );
      final adapter = _FakeAdapter(
        sourceId: 'source:a',
        pages: const {},
        error: StateError('offline'),
      );
      final scanner = CoordinatedLibraryScanner(
        repository: repository,
        adapters: [adapter],
        metadataResolver: const _PassthroughResolver(),
      );
      final failed = Completer<ScanProgress>();
      final subscription = scanner.progress.listen((event) {
        if (event.state == ScanState.failed && !failed.isCompleted) {
          failed.complete(event);
        }
      });

      await scanner.refreshRoots([_root('root-id', adapter.sourceId)]);
      expect((await failed.future).error, isA<StateError>());
      final old = (await repository.snapshot()).files['source:a:old.mkv']!;
      expect(old.availability, MediaAvailability.available);
      expect(old.rootIds, contains('root-id'));
      await subscription.cancel();
    },
  );

  test('one failing source does not block another source', () async {
    final failing = _FakeAdapter(
      sourceId: 'source:bad',
      pages: const {},
      error: StateError('offline'),
    );
    final healthy = _FakeAdapter(
      sourceId: 'source:good',
      pages: {
        'root|': ListingPage(
          entries: [_videoEntry('works.webm', sourceId: 'source:good')],
        ),
      },
    );
    final scanner = CoordinatedLibraryScanner(
      repository: repository,
      adapters: [failing, healthy],
      metadataResolver: const _PassthroughResolver(),
    );

    await scanner.refreshRoots([
      _root('bad-root', failing.sourceId),
      _root('good-root', healthy.sourceId),
    ]);
    final data = await repository.snapshot();
    expect(data.files, contains('source:good:works.webm'));
  });

  test('commits discovery before a slow metadata lookup completes', () async {
    final adapter = _FakeAdapter(
      sourceId: 'source:a',
      pages: {
        'root|': ListingPage(entries: [_videoEntry('slow.mkv')]),
      },
    );
    final resolver = _BlockingResolver();
    final scanner = CoordinatedLibraryScanner(
      repository: repository,
      adapters: [adapter],
      metadataResolver: resolver,
    );

    final scan = scanner.refreshRoots([_root('root-id', adapter.sourceId)]);
    final discovered = await repository.watch().firstWhere(
      (snapshot) => snapshot.files.containsKey('source:a:slow.mkv'),
    );
    expect(
      discovered.files['source:a:slow.mkv']!.identificationState,
      MetadataState.unresolved,
    );

    resolver.release.complete();
    await scan;
    expect(
      (await repository.snapshot())
          .files['source:a:slow.mkv']!
          .identificationState,
      MetadataState.noMatch,
    );
  });

  test('a bad STRM is partial but does not stop sibling discovery', () async {
    final adapter = _FakeAdapter(
      sourceId: 'source:a',
      smallText: 'ftp://unsupported/movie.mkv',
      pages: {
        'root|': ListingPage(
          entries: [
            _videoEntry('bad.strm', isStrm: true),
            _videoEntry('good.mkv'),
          ],
        ),
      },
    );
    final scanner = CoordinatedLibraryScanner(
      repository: repository,
      adapters: [adapter],
      metadataResolver: const _PassthroughResolver(),
    );
    final states = <ScanState>[];
    final subscription = scanner.progress.listen(
      (event) => states.add(event.state),
    );

    await scanner.refreshRoots([_root('root-id', adapter.sourceId)]);
    final files = (await repository.snapshot()).files;
    expect(files.keys, containsAll(['source:a:bad.strm', 'source:a:good.mkv']));
    expect(
      files['source:a:bad.strm']!.identificationState,
      MetadataState.failed,
    );
    expect(states, contains(ScanState.partial));
    await subscription.cancel();
  });

  test('cancelled metadata request cannot append a late result', () async {
    final adapter = _FakeAdapter(
      sourceId: 'source:a',
      pages: {
        'root|': ListingPage(entries: [_videoEntry('slow.mkv')]),
      },
    );
    final resolver = _BlockingResolver();
    final scanner = CoordinatedLibraryScanner(
      repository: repository,
      adapters: [adapter],
      metadataResolver: resolver,
    );
    final scan = scanner.refreshRoots([_root('root-id', adapter.sourceId)]);
    await repository.watch().firstWhere(
      (snapshot) => snapshot.files.containsKey('source:a:slow.mkv'),
    );
    scanner.cancel('root-id');
    resolver.release.complete();
    await scan;
    expect(
      (await repository.snapshot())
          .files['source:a:slow.mkv']!
          .identificationState,
      MetadataState.unresolved,
    );
  });
}

LibraryRoot _root(String id, String sourceId) => LibraryRoot(
  id: id,
  sourceId: sourceId,
  displayName: id,
  directory: SourceDirectory(
    sourceId: sourceId,
    sourceType: 'test',
    identity: 'root',
    path: 'root',
    contextName: 'Shows',
  ),
);

SourceEntry _directoryEntry(String name, {String? identity}) => SourceEntry(
  name: name,
  stableId: 'directory:$name',
  isDirectory: true,
  directory: SourceDirectory(
    sourceId: 'source:a',
    sourceType: 'test',
    identity: identity ?? name,
    path: identity ?? name,
    contextName: name,
  ),
);

SourceEntry _videoEntry(
  String name, {
  String sourceId = 'source:a',
  bool isStrm = false,
}) => SourceEntry(
  name: name,
  stableId: '$sourceId:$name',
  isDirectory: false,
  sourceRef: MediaSourceRef(
    sourceId: sourceId,
    sourceType: 'test',
    path: '/$name',
  ),
  sizeBytes: 123,
  legacyResumeKey: '$sourceId:$name',
  isStrm: isStrm,
);

MediaFile _indexedFile(String id) => MediaFile(
  id: id,
  rootIds: const {'root-id'},
  sourceRef: const MediaSourceRef(
    sourceId: 'source:a',
    sourceType: 'test',
    path: '/old.mkv',
  ),
  originalFileName: 'old.mkv',
  availability: MediaAvailability.available,
  legacyResumeKey: id,
);

class _PassthroughResolver implements MetadataResolver {
  const _PassthroughResolver();

  @override
  Future<MatchResult> resolve(MediaFile file, DiscoveryContext context) async =>
      MatchResult(file: file);
}

class _BlockingResolver implements MetadataResolver {
  final Completer<void> release = Completer<void>();

  @override
  Future<MatchResult> resolve(MediaFile file, DiscoveryContext context) async {
    await release.future;
    return MatchResult(
      file: file.copyWith(identificationState: MetadataState.noMatch),
    );
  }
}

class _FakeAdapter
    implements LibrarySourceAdapter, SmallTextLibrarySourceAdapter {
  _FakeAdapter({
    required this.sourceId,
    required this.pages,
    this.error,
    this.smallText = 'https://example.test/video.mkv',
  });

  @override
  final String sourceId;
  final Map<String, ListingPage> pages;
  final Object? error;
  final String smallText;
  final List<String> calls = [];

  @override
  Future<ListingPage> list(SourceDirectory directory, {String? cursor}) async {
    final key = '${directory.identity}|${cursor ?? ''}';
    calls.add(key);
    if (error != null) throw error!;
    return pages[key] ?? const ListingPage(entries: []);
  }

  @override
  Future<VideoItem> resolvePlayable(MediaFile file) {
    throw UnimplementedError();
  }

  @override
  Future<String?> readSmallText(MediaFile file, {int maxBytes = 65536}) async =>
      smallText;
}

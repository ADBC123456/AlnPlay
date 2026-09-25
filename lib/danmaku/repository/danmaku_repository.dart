// Cache-first danmaku repository.
//
// Flow per video (requirement 15): read valid cache -> request via the source
// -> normalize -> write cache. Already-cached episodes are never re-requested
// by default (requirement 16); callers pass `forceRefresh: true` to bypass.

import '../source/danmaku_source_registry.dart';
import '../identity/video_identity.dart';
import 'danmaku_cache.dart';

/// Outcome of one repository fetch.
enum DanmakuFetchStatus {
  /// Served from cache (no network request happened).
  fromCache,

  /// Fetched from the network and written to cache.
  fromNetwork,

  /// The source matched the video but returned zero comments.
  empty,

  /// The source could not match this video to any episode.
  noMatch,

  /// A typed failure occurred (see [DanmakuFetchResult.error]).
  failed,
}

/// Result of [DanmakuRepository.loadForVideo].
class DanmakuFetchResult {
  const DanmakuFetchResult._({required this.status, this.entry, this.error});

  final DanmakuFetchStatus status;

  /// The cached or freshly fetched entry. Null for noMatch/failed.
  final DanmakuCacheEntry? entry;

  /// Typed error for [DanmakuFetchStatus.failed].
  final DanmakuSourceException? error;

  bool get hasComments => entry != null && entry!.comments.isNotEmpty;
}

/// Request sent to the repository. [videoIdentity] must be a stable identity
/// for the video: `md5:first16MiB` when the hash is computable, otherwise a
/// stable URI/path + filename + size composite (PRD cache rules).
class DanmakuVideoRequest {
  const DanmakuVideoRequest({
    required this.videoIdentity,
    required this.fileName,
    this.fileHash,
    this.fileSize,
    this.videoKey,
  });

  final String fileName;
  final String? fileHash;
  final int? fileSize;

  /// Optional display key for the cache entry; defaults to [fileName].
  final String? videoKey;

  /// Stable identity string used for cache keying.
  final String videoIdentity;
}

/// Cache-first facade over [DanmakuSource]s.
class DanmakuRepository {
  DanmakuRepository({
    required this.cache,
    DanmakuSourceRegistry? registry,
    DateTime Function()? clock,
  }) : registry = registry ?? DanmakuSourceRegistry.instance,
       _clock = clock ?? DateTime.now;

  static const Duration emptyCacheTtl = Duration(minutes: 5);

  final DanmakuCache cache;

  /// Registry used to resolve [sourceId] -> source. Defaults to the global
  /// singleton; injectable for tests.
  final DanmakuSourceRegistry registry;
  final DateTime Function() _clock;
  final Map<String, int> _requestGenerations = {};
  final Map<String, Future<void>> _writeTails = {};

  /// Loads comments for [request] via [sourceId], honoring the cache.
  ///
  /// - Cache hit -> [DanmakuFetchStatus.fromCache] without any network call.
  /// - Miss -> match -> fetch -> write cache -> [DanmakuFetchStatus.fromNetwork]
  ///   (or `empty` when the episode has zero comments).
  /// - No remote match -> [DanmakuFetchStatus.noMatch] (nothing cached).
  /// - Typed failure -> [DanmakuFetchStatus.failed] with the error carried.
  Future<DanmakuFetchResult> loadForVideo({
    required String sourceId,
    required String baseUrl,
    required DanmakuVideoRequest request,
    String? matchMode,
    DanmakuCancelToken? cancelToken,
    bool forceRefresh = false,
    DanmakuProgressCallback? onProgress,
  }) async {
    if (!forceRefresh) {
      final cached = await cache.read(
        sourceId: sourceId,
        baseUrl: baseUrl,
        videoIdentity: request.videoIdentity,
      );
      if (cached != null && _isCacheValid(cached)) {
        _report(
          onProgress,
          DanmakuLoadProgress(
            phase: DanmakuLoadPhase.parsing,
            sourceId: sourceId,
          ),
        );
        return DanmakuFetchResult._(
          status: cached.comments.isEmpty
              ? DanmakuFetchStatus.empty
              : DanmakuFetchStatus.fromCache,
          entry: cached,
        );
      }
    }

    final source = registry.sourceFor(sourceId);
    if (source == null) {
      return DanmakuFetchResult._(
        status: DanmakuFetchStatus.failed,
        error: DanmakuSourceException('Unknown danmaku source: $sourceId'),
      );
    }
    final requestGeneration = _beginRequest(
      sourceId,
      baseUrl,
      request.videoIdentity,
    );

    try {
      _report(
        onProgress,
        DanmakuLoadProgress(
          phase: DanmakuLoadPhase.matching,
          sourceId: sourceId,
        ),
      );
      final match = await source.match(
        fileName: request.fileName,
        fileHash: request.fileHash,
        fileSize: request.fileSize,
        matchMode: matchMode,
        cancelToken: cancelToken,
      );
      if (match == null) {
        return const DanmakuFetchResult._(status: DanmakuFetchStatus.noMatch);
      }

      final comments = await _fetchComments(
        source,
        sourceId: sourceId,
        episodeId: match.episodeId,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );

      final shiftedComments = _shiftComments(comments.comments, match.shift);
      final entry = DanmakuCacheEntry(
        sourceId: sourceId,
        baseUrl: baseUrl,
        videoKey: request.videoIdentity,
        fileName: request.fileName,
        animeId: match.animeId,
        episodeId: match.episodeId,
        fetchedAtMs: _clock().millisecondsSinceEpoch,
        videoDurationSeconds: comments.videoDurationSeconds,
        appliedShiftSeconds: match.shift.toDouble(),
        comments: shiftedComments,
      );
      await _writeIfCurrent(
        sourceId,
        baseUrl,
        request.videoIdentity,
        requestGeneration,
        entry,
      );
      return DanmakuFetchResult._(
        status: entry.comments.isEmpty
            ? DanmakuFetchStatus.empty
            : DanmakuFetchStatus.fromNetwork,
        entry: entry,
      );
    } on DanmakuCancelledException {
      rethrow;
    } on DanmakuSourceException catch (e) {
      return DanmakuFetchResult._(status: DanmakuFetchStatus.failed, error: e);
    }
  }

  /// Fetches comments for an already-known episode (manual match /
  /// batch-scrape flows that resolved the episode via search or bangumi).
  /// Cache write still uses the video identity.
  Future<DanmakuFetchResult> loadForEpisode({
    required String sourceId,
    required String baseUrl,
    required DanmakuVideoRequest request,
    required String episodeId,
    num shiftSeconds = 0,
    DanmakuCancelToken? cancelToken,
    bool forceRefresh = false,
    DanmakuProgressCallback? onProgress,
  }) async {
    if (!forceRefresh) {
      final cached = await cache.read(
        sourceId: sourceId,
        baseUrl: baseUrl,
        videoIdentity: request.videoIdentity,
      );
      if (cached != null &&
          cached.episodeId == episodeId &&
          _isCacheValid(cached)) {
        _report(
          onProgress,
          DanmakuLoadProgress(
            phase: DanmakuLoadPhase.parsing,
            sourceId: sourceId,
          ),
        );
        return DanmakuFetchResult._(
          status: cached.comments.isEmpty
              ? DanmakuFetchStatus.empty
              : DanmakuFetchStatus.fromCache,
          entry: cached,
        );
      }
    }

    final source = registry.sourceFor(sourceId);
    if (source == null) {
      return DanmakuFetchResult._(
        status: DanmakuFetchStatus.failed,
        error: DanmakuSourceException('Unknown danmaku source: $sourceId'),
      );
    }
    final requestGeneration = _beginRequest(
      sourceId,
      baseUrl,
      request.videoIdentity,
    );

    try {
      final comments = await _fetchComments(
        source,
        sourceId: sourceId,
        episodeId: episodeId,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
      final entry = DanmakuCacheEntry(
        sourceId: sourceId,
        baseUrl: baseUrl,
        videoKey: request.videoIdentity,
        fileName: request.fileName,
        animeId: '',
        episodeId: episodeId,
        fetchedAtMs: _clock().millisecondsSinceEpoch,
        videoDurationSeconds: comments.videoDurationSeconds,
        appliedShiftSeconds: shiftSeconds.toDouble(),
        comments: _shiftComments(comments.comments, shiftSeconds),
      );
      await _writeIfCurrent(
        sourceId,
        baseUrl,
        request.videoIdentity,
        requestGeneration,
        entry,
      );
      return DanmakuFetchResult._(
        status: entry.comments.isEmpty
            ? DanmakuFetchStatus.empty
            : DanmakuFetchStatus.fromNetwork,
        entry: entry,
      );
    } on DanmakuCancelledException {
      rethrow;
    } on DanmakuSourceException catch (e) {
      return DanmakuFetchResult._(status: DanmakuFetchStatus.failed, error: e);
    }
  }

  static List<DanmakuSourceComment> _shiftComments(
    List<DanmakuSourceComment> comments,
    num shiftSeconds,
  ) {
    final shift = shiftSeconds.toDouble();
    if (shift == 0) return comments;
    return [
      for (final comment in comments)
        if (comment.timeSeconds + shift >= 0)
          DanmakuSourceComment(
            timeSeconds: comment.timeSeconds + shift,
            mode: comment.mode,
            colorRgb: comment.colorRgb,
            content: comment.content,
            danmakuId: comment.danmakuId,
            likes: comment.likes,
          ),
    ];
  }

  bool _isCacheValid(DanmakuCacheEntry entry) {
    if (entry.comments.isNotEmpty) return true;
    final age = _clock().millisecondsSinceEpoch - entry.fetchedAtMs;
    return age >= 0 && age < emptyCacheTtl.inMilliseconds;
  }

  String _operationKey(String sourceId, String baseUrl, String identity) =>
      '$sourceId\u0000$baseUrl\u0000${normalizeDanmakuIdentityKey(identity)}';

  int _beginRequest(String sourceId, String baseUrl, String identity) {
    final key = _operationKey(sourceId, baseUrl, identity);
    return _requestGenerations[key] = (_requestGenerations[key] ?? 0) + 1;
  }

  bool _isCurrentRequest(
    String sourceId,
    String baseUrl,
    String identity,
    int generation,
  ) =>
      _requestGenerations[_operationKey(sourceId, baseUrl, identity)] ==
      generation;

  Future<void> _writeIfCurrent(
    String sourceId,
    String baseUrl,
    String identity,
    int generation,
    DanmakuCacheEntry entry,
  ) async {
    final key = _operationKey(sourceId, baseUrl, identity);
    final previous = _writeTails[key] ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous
        .catchError((_) {})
        .then((_) async {
          if (_isCurrentRequest(sourceId, baseUrl, identity, generation)) {
            await cache.write(entry);
          }
        })
        .whenComplete(() {
          if (identical(_writeTails[key], operation)) _writeTails.remove(key);
        });
    _writeTails[key] = operation;
    await operation;
  }

  Future<DanmakuSourceComments> _fetchComments(
    DanmakuSource source, {
    required String sourceId,
    required String episodeId,
    DanmakuCancelToken? cancelToken,
    DanmakuProgressCallback? onProgress,
  }) async {
    if (source is ProgressiveDanmakuSource) {
      return (source as ProgressiveDanmakuSource).fetchCommentsWithProgress(
        episodeId: episodeId,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    }
    _report(
      onProgress,
      DanmakuLoadProgress(
        phase: DanmakuLoadPhase.downloading,
        sourceId: sourceId,
      ),
    );
    final comments = await source.fetchComments(
      episodeId: episodeId,
      cancelToken: cancelToken,
    );
    _report(
      onProgress,
      DanmakuLoadProgress(phase: DanmakuLoadPhase.parsing, sourceId: sourceId),
    );
    return comments;
  }

  static void _report(
    DanmakuProgressCallback? callback,
    DanmakuLoadProgress progress,
  ) {
    if (callback == null) return;
    try {
      callback(progress);
    } catch (_) {}
  }
}

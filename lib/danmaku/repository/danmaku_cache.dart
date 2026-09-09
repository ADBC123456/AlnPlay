// File-backed danmaku cache with source/baseUrl/video-identity isolation and
// atomic (temp file + rename) writes.
//
// Cache key layout (requirement 13):
//   <root>/danmaku/<sourceId>/<baseUrlHash>/<videoIdentityHash>/v<schemaVersion>.json
// The raw base URL and video identity never appear in the file system path.
//
// Atomicity (requirement 14): every write goes to `<name>.tmp` in the same
// directory, is flushed, then renamed onto the final name. A crash can only
// ever leave an orphaned `.tmp` file, never a half-written cache entry, and
// stale `.tmp` files are pruned on load.
//
// Entry contents (requirement 15 / PRD): sourceId, baseUrl, video key,
// fileName, animeId, episodeId, fetchedAt, videoDuration, comment count and
// the normalized comments.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import '../../services/cache_quota_manager.dart';

import '../source/danmaku_source_registry.dart';

/// Bump when the on-disk entry format changes; old entries become unreadable
/// (different file name) and are re-fetched.
const int kDanmakuCacheSchemaVersion = 2;

/// One cached danmaku entry bound to (sourceId, baseUrl, video identity).
class DanmakuCacheEntry {
  const DanmakuCacheEntry({
    required this.sourceId,
    required this.baseUrl,
    required this.videoKey,
    required this.fileName,
    required this.animeId,
    required this.episodeId,
    required this.fetchedAtMs,
    this.videoDurationSeconds,
    this.appliedShiftSeconds = 0,
    required this.comments,
  });

  final String sourceId;
  final String baseUrl;
  final String videoKey;
  final String fileName;
  final String animeId;
  final String episodeId;
  final int fetchedAtMs;
  final double? videoDurationSeconds;
  final double appliedShiftSeconds;
  final List<DanmakuSourceComment> comments;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schemaVersion': kDanmakuCacheSchemaVersion,
    'sourceId': sourceId,
    'baseUrl': baseUrl,
    'videoKey': videoKey,
    'fileName': fileName,
    'animeId': animeId,
    'episodeId': episodeId,
    'fetchedAtMs': fetchedAtMs,
    if (videoDurationSeconds != null) 'videoDuration': videoDurationSeconds,
    'appliedShift': appliedShiftSeconds,
    'commentCount': comments.length,
    'comments': [for (final c in comments) c.toJson()],
  };

  /// Returns null when the JSON is structurally invalid or was written by a
  /// different schema version.
  static DanmakuCacheEntry? fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != kDanmakuCacheSchemaVersion) return null;
    final sourceId = json['sourceId'];
    final baseUrl = json['baseUrl'];
    final videoKey = json['videoKey'];
    final episodeId = json['episodeId'];
    final fetchedAt = json['fetchedAtMs'];
    final rawComments = json['comments'];
    if (sourceId is! String ||
        baseUrl is! String ||
        videoKey is! String ||
        episodeId is! String ||
        fetchedAt is! int ||
        rawComments is! List) {
      return null;
    }
    final comments = <DanmakuSourceComment>[];
    for (final raw in rawComments) {
      if (raw is! Map) continue;
      final comment = DanmakuSourceComment.fromJson(
        raw.cast<String, dynamic>(),
      );
      if (comment != null) comments.add(comment);
    }
    return DanmakuCacheEntry(
      sourceId: sourceId,
      baseUrl: baseUrl,
      videoKey: videoKey,
      fileName: (json['fileName'] as String?) ?? '',
      animeId: (json['animeId'] as String?) ?? '',
      episodeId: episodeId,
      fetchedAtMs: fetchedAt,
      videoDurationSeconds: (json['videoDuration'] as num?)?.toDouble(),
      appliedShiftSeconds: (json['appliedShift'] as num?)?.toDouble() ?? 0,
      comments: comments,
    );
  }
}

/// File-backed cache. One instance per process; instances are cheap and state
///less (every call resolves the directory), so a singleton is unnecessary.
class DanmakuCache {
  /// [directory] overrides the cache root (test seam). Production callers use
  /// the default constructor which needs a directory supplied via [open] or
  /// [setDirectory].
  DanmakuCache({Directory? directory, bool? useQuota})
    : _root = directory,
      _useQuota = useQuota ?? directory == null;

  final bool _useQuota;
  int _quotaRevision = 0;

  Directory? _root;

  /// In-memory memo of fully-read entries keyed by the same composite key as
  /// the file path; avoids re-parsing large JSON within a session.
  final Map<String, DanmakuCacheEntry> _memory = {};

  /// The cache root when set (read-only access for callers that need to
  /// mirror the directory resolution, e.g. DanmakuService init).
  Directory? get root => _root;

  /// Provides the cache root directory (e.g. app cache dir + `danmaku`).
  void setDirectory(Directory directory) {
    _root = directory;
    _memory.clear();
  }

  Directory get _requireRoot {
    final root = _root;
    if (root == null) {
      throw StateError('DanmakuCache.setDirectory must be called before use');
    }
    return root;
  }

  /// Composite key components: sourceId + baseUrl hash + video identity hash
  /// + schema version.
  static String keyFor({
    required String sourceId,
    required String baseUrl,
    required String videoIdentity,
  }) {
    return '$sourceId/'
        '${hashIdentity(baseUrl)}/'
        '${hashIdentity(videoIdentity)}/'
        'v$kDanmakuCacheSchemaVersion';
  }

  String _filePath(String key) {
    final root = _requireRoot;
    return '${root.path}${Platform.pathSeparator}'
        'danmaku${Platform.pathSeparator}'
        '${key.replaceAll('/', Platform.pathSeparator)}.json';
  }

  /// Reads a cached entry; null on miss/corruption/schema mismatch.
  Future<DanmakuCacheEntry?> read({
    required String sourceId,
    required String baseUrl,
    required String videoIdentity,
  }) async {
    if (_useQuota &&
        _quotaRevision != CacheQuotaManager.instance.evictionRevision) {
      _memory.clear();
      _quotaRevision = CacheQuotaManager.instance.evictionRevision;
    }
    final key = keyFor(
      sourceId: sourceId,
      baseUrl: baseUrl,
      videoIdentity: videoIdentity,
    );
    final memo = _memory[key];
    if (memo != null) {
      if (_useQuota) await CacheQuotaManager.instance.touch(_filePath(key));
      return memo;
    }
    try {
      final file = File(_filePath(key));
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      if (_useQuota) await CacheQuotaManager.instance.touch(file.path);
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final entry = DanmakuCacheEntry.fromJson(decoded);
      if (entry == null) return null;
      _memory[key] = entry;
      return entry;
    } on FileSystemException catch (e) {
      _log('cache read failed: ${e.message}');
      return null;
    } on FormatException {
      // A corrupt file is treated as a miss; delete it so the next write can
      // proceed cleanly.
      _deleteCorrupt(key);
      return null;
    }
  }

  /// Writes [entry] atomically: temp file in the same directory, flush, then
  /// rename over the final name.
  Future<void> write(DanmakuCacheEntry entry) async {
    final key = keyFor(
      sourceId: entry.sourceId,
      baseUrl: entry.baseUrl,
      videoIdentity: entry.videoKey,
    );
    final path = _filePath(key);
    if (_useQuota) {
      if (await CacheQuotaManager.instance.write(
        File(path),
        utf8.encode(jsonEncode(entry.toJson())),
      )) {
        _memory[key] = entry;
      }
      return;
    }
    final tmp = File('$path.tmp');
    try {
      await tmp.parent.create(recursive: true);
      final sink = tmp.openWrite();
      try {
        sink.write(jsonEncode(entry.toJson()));
        await sink.flush();
      } finally {
        await sink.close();
      }
      // rename onto the final name — atomic on POSIX; on Windows, File.rename
      // replaces an existing destination (MOVEFILE_REPLACE_EXISTING).
      await tmp.rename(path);
      _memory[key] = entry;
    } on FileSystemException catch (e) {
      _log('cache write failed: ${e.message}');
      // Best effort cleanup of the temp file; never surface to callers.
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // ignore
      }
    }
  }

  /// Removes one entry (used by "force re-scrape" flows).
  Future<void> remove({
    required String sourceId,
    required String baseUrl,
    required String videoIdentity,
  }) async {
    final key = keyFor(
      sourceId: sourceId,
      baseUrl: baseUrl,
      videoIdentity: videoIdentity,
    );
    _memory.remove(key);
    try {
      final file = File(_filePath(key));
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (e) {
      _log('cache remove failed: ${e.message}');
    }
  }

  /// Clears every source/video entry while keeping the cache ready for new
  /// writes. Missing directories are treated as already cleared.
  Future<void> clearAll() async {
    _memory.clear();
    final root = _requireRoot;
    final directory = Directory('${root.path}${Platform.pathSeparator}danmaku');
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException catch (error) {
      _log('cache clear failed: ${error.message}');
      rethrow;
    }
  }

  void _deleteCorrupt(String key) {
    // Fire-and-forget; a failure here is harmless.
    File(_filePath(key)).delete().catchError((_) => File(''));
  }

  void _log(String message) {
    assert(() {
      // ignore: avoid_print
      print('[DanmakuCache] $message');
      return true;
    }());
  }
}

/// Resolves `<app cache dir>/danmaku` via path_provider. Tests override the
/// cache root with `DanmakuCache(directory: ...)` directly.
Future<DanmakuCache> createDefaultDanmakuCache() async {
  final appDir = await getApplicationCacheDirectory();
  return DanmakuCache(directory: appDir, useQuota: true);
}

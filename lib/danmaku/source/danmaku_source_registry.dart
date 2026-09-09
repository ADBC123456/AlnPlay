// Danmaku source contract + registry.
//
// NOTE: per the task split this file intentionally hosts the shared
// source-contract value types (match/episode/comment models, cancel token,
// identity hashing) alongside the registry, because the dedicated
// `model/` + `parser/` layers belong to another agent. When those layers
// land, the value types below can move there without changing call sites.

import 'dart:async';

/// Stable FNV-1a 64-bit hash of [input] as lowercase hex.
///
/// Used for cache-key components (base URL, video identity) so raw URLs and
/// paths never appear in file names. 64-bit int math wraps on VM/Android/iOS
/// (all dart:io targets this cache supports); this file must not be compiled
/// for web.
String hashIdentity(String input) {
  var hash = 0xcbf29ce484222325;
  for (final code in input.codeUnits) {
    hash ^= code & 0xff;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    hash ^= (code >> 8) & 0xff;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

enum DanmakuLoadPhase { matching, downloading, parsing }

typedef DanmakuProgressCallback = void Function(DanmakuLoadProgress progress);

class DanmakuLoadProgress {
  const DanmakuLoadProgress({
    required this.phase,
    this.sourceId,
    this.bytesReceived,
    this.totalBytes,
    this.bytesPerSecond,
  });

  final DanmakuLoadPhase phase;
  final String? sourceId;
  final int? bytesReceived;
  final int? totalBytes;
  final double? bytesPerSecond;

  /// Null when the server omitted Content-Length.
  double? get fraction =>
      bytesReceived != null && totalBytes != null && totalBytes! > 0
      ? (bytesReceived! / totalBytes!).clamp(0, 1)
      : null;
}

/// Cooperative cancellation handle for source requests.
///
/// Sources poll [isCancelled] between steps and abort in-flight HTTP
/// requests; waiting on [whenCancelled] lets them react immediately.
class DanmakuCancelToken {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Base class for every error a [DanmakuSource] can surface.
class DanmakuSourceException implements Exception {
  const DanmakuSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when the caller cancelled the request.
class DanmakuCancelledException extends DanmakuSourceException {
  const DanmakuCancelledException([
    super.message = 'Danmaku request cancelled',
  ]);
}

/// Network-level failure (DNS, socket, TLS, timeout). Retryable.
class DanmakuNetworkException extends DanmakuSourceException {
  const DanmakuNetworkException(super.message);
}

/// HTTP 429 from the service. Retryable.
class DanmakuRateLimitException extends DanmakuSourceException {
  const DanmakuRateLimitException(super.message, {this.retryAfter});

  /// Server-provided wait hint in seconds, when the response carried a valid
  /// `Retry-After` header.
  final Duration? retryAfter;
}

/// HTTP 5xx from the service. Retryable.
class DanmakuServerException extends DanmakuSourceException {
  const DanmakuServerException(super.message);
}

/// HTTP 401/403 — token or service configuration problem. Not retryable.
class DanmakuAuthException extends DanmakuSourceException {
  const DanmakuAuthException(super.message);
}

/// Other 4xx (bad request, unknown anime/episode id, ...). Not retryable.
class DanmakuRequestException extends DanmakuSourceException {
  const DanmakuRequestException(super.message);
}

/// The service answered but the body is not a usable danmu_api payload.
/// Not retryable.
class DanmakuProtocolException extends DanmakuSourceException {
  const DanmakuProtocolException(super.message);
}

/// One matched remote episode for a video file.
class DanmakuSourceMatch {
  const DanmakuSourceMatch({
    required this.episodeId,
    required this.animeId,
    required this.animeTitle,
    required this.episodeTitle,
    this.shift = 0,
    this.url = '',
  });

  /// Remote episode id, always normalized to a string (ids must survive
  /// numeric OR string transport without precision loss).
  final String episodeId;

  /// Remote anime id, always a string.
  final String animeId;

  final String animeTitle;
  final String episodeTitle;

  /// Time shift in seconds the server applied to (or reports for) this match.
  final int shift;

  /// Source page url reported by the service (informational; may be empty).
  final String url;
}

/// A single normalized comment coming from (or going into) the cache.
///
/// Protocol mode codes are preserved: 1/6/7 scroll, 4 bottom, 5 top.
class DanmakuSourceComment {
  const DanmakuSourceComment({
    required this.timeSeconds,
    required this.mode,
    required this.colorRgb,
    required this.content,
    this.danmakuId,
    this.likes,
  });

  final double timeSeconds;
  final int mode;
  final int colorRgb;
  final String content;
  final String? danmakuId;
  final int? likes;

  Map<String, dynamic> toJson() => <String, dynamic>{
    't': timeSeconds,
    'mo': mode,
    'c': colorRgb,
    'm': content,
    if (danmakuId != null) 'cid': danmakuId,
    if (likes != null) 'like': likes,
  };

  static DanmakuSourceComment? fromJson(Map<String, dynamic> json) {
    final time = _doubleOf(json['t']);
    final mode = _intOf(json['mo']);
    final color = _intOf(json['c']);
    final content = json['m'];
    if (time == null ||
        time < 0 ||
        mode == null ||
        color == null ||
        content is! String ||
        content.isEmpty) {
      return null;
    }
    return DanmakuSourceComment(
      timeSeconds: time,
      mode: mode,
      colorRgb: color & 0xFFFFFF,
      content: content,
      danmakuId: json['cid']?.toString(),
      likes: _intOf(json['like']),
    );
  }

  static double? _doubleOf(Object? value) => switch (value) {
    num n => n.toDouble(),
    String s => double.tryParse(s.trim()),
    _ => null,
  };

  static int? _intOf(Object? value) => switch (value) {
    num n => n.toInt(),
    String s => num.tryParse(s.trim())?.toInt(),
    _ => null,
  };
}

/// Comments of one episode plus the optional server-reported duration.
class DanmakuSourceComments {
  const DanmakuSourceComments({
    required this.comments,
    this.videoDurationSeconds,
  });

  final List<DanmakuSourceComment> comments;

  /// `videoDuration` reported by the service when `duration=true` (seconds).
  final double? videoDurationSeconds;
}

/// An episode listed under an anime by search / bangumi endpoints.
class DanmakuSourceEpisode {
  const DanmakuSourceEpisode({
    required this.episodeId,
    required this.episodeTitle,
    this.url = '',
  });

  final String episodeId;
  final String episodeTitle;
  final String url;
}

/// An anime with its episode list (search/episodes and bangumi responses).
class DanmakuSourceEpisodeGroup {
  const DanmakuSourceEpisodeGroup({
    required this.animeId,
    required this.animeTitle,
    required this.episodes,
  });

  final String animeId;
  final String animeTitle;
  final List<DanmakuSourceEpisode> episodes;
}

/// One segment request body for the `segmentcomment` endpoint.
class DanmakuSegment {
  const DanmakuSegment({
    required this.type,
    required this.segmentStart,
    required this.segmentEnd,
    required this.url,
    this.data,
  });

  final String type;
  final int segmentStart;
  final int segmentEnd;
  final String url;
  final String? data;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type,
    'segment_start': segmentStart,
    'segment_end': segmentEnd,
    'url': url,
    if (data != null) 'data': data,
  };
}

/// A pluggable danmaku provider.
///
/// Implementations must never log tokens, cookies, app secrets or URLs that
/// embed credentials, and must only send credentials to their own configured
/// service address.
abstract interface class DanmakuSource {
  /// Stable registry id, e.g. `danmu_api`.
  String get sourceId;

  /// Human-readable name for settings UI.
  String get displayName;

  /// Stable opaque hash of this source's *service address* configuration.
  ///
  /// Two configurations of the same source type pointing at different
  /// deployments MUST produce different scopes so caches never cross.
  String get cacheScope;

  /// Best-effort connectivity probe. Throws [DanmakuSourceException] on any
  /// failure; completes normally when the service answered successfully.
  Future<void> verifyConnectivity({DanmakuCancelToken? cancelToken});

  /// Matches a video file to one remote episode. Returns `null` when the
  /// service matched nothing (not an error).
  Future<DanmakuSourceMatch?> match({
    required String fileName,
    String? fileHash,
    int? fileSize,
    String? matchMode,
    DanmakuCancelToken? cancelToken,
  });

  /// Fetches all comments of one episode.
  Future<DanmakuSourceComments> fetchComments({
    required String episodeId,
    DanmakuCancelToken? cancelToken,
  });

  /// Searches anime by title and returns each match with its episodes.
  Future<List<DanmakuSourceEpisodeGroup>> searchEpisodes({
    required String anime,
    DanmakuCancelToken? cancelToken,
  });

  /// Loads one anime's episode list by id. `null` when the service does not
  /// know the id.
  Future<DanmakuSourceEpisodeGroup?> bangumi({required String animeId});

  /// Fetches comments for one segment (server-side sharded episodes).
  Future<List<DanmakuSourceComment>> fetchSegmentComments({
    required DanmakuSegment segment,
    DanmakuCancelToken? cancelToken,
  });
}

/// Optional source capability for byte-accurate comment download progress.
abstract interface class ProgressiveDanmakuSource {
  Future<DanmakuSourceComments> fetchCommentsWithProgress({
    required String episodeId,
    DanmakuCancelToken? cancelToken,
    DanmakuProgressCallback? onProgress,
  });
}

/// One registered source plus its user-facing state.
class DanmakuSourceHandle {
  DanmakuSourceHandle(this.source, {this.enabled = true, this.priority = 0});

  final DanmakuSource source;
  bool enabled;
  int priority;
}

/// Registry of available danmaku sources with enable/disable and priority.
///
/// Priority is ordered descending (higher value = tried first); sources with
/// equal priority keep registration order.
class DanmakuSourceRegistry {
  DanmakuSourceRegistry();

  static final DanmakuSourceRegistry instance = DanmakuSourceRegistry();

  final Map<String, DanmakuSourceHandle> _handles =
      <String, DanmakuSourceHandle>{};

  /// Registers or replaces [source]. A replacement keeps the map position but
  /// uses the new client instance, so editing a URL/token takes effect now.
  void register(DanmakuSource source, {bool enabled = true, int priority = 0}) {
    _handles[source.sourceId] = DanmakuSourceHandle(
      source,
      enabled: enabled,
      priority: priority,
    );
  }

  void unregister(String sourceId) => _handles.remove(sourceId);

  DanmakuSource? sourceFor(String sourceId) => _handles[sourceId]?.source;

  bool isEnabled(String sourceId) => _handles[sourceId]?.enabled ?? false;

  void setEnabled(String sourceId, bool enabled) {
    final handle = _handles[sourceId];
    if (handle != null) handle.enabled = enabled;
  }

  void setPriority(String sourceId, int priority) {
    final handle = _handles[sourceId];
    if (handle != null) handle.priority = priority;
  }

  int? priorityOf(String sourceId) => _handles[sourceId]?.priority;

  /// Enabled sources ordered by priority (descending), registration order
  /// within equal priority.
  List<DanmakuSource> get enabledSources {
    final entries = _handles.values.where((h) => h.enabled).toList()
      ..sort((a, b) {
        final byPriority = b.priority.compareTo(a.priority);
        return byPriority;
      });
    return entries.map((h) => h.source).toList();
  }

  /// All registered sources in registration order (for the settings list).
  List<DanmakuSource> get sources =>
      _handles.values.map((h) => h.source).toList();

  /// Clears every registration (test seam).
  void resetForTesting() => _handles.clear();
}

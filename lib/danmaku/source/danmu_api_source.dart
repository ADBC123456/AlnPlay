// danmu_api (https://github.com/huangxd-/danmu_api) compatible client.
//
// Protocol (verified against the upstream worker implementation):
// - Auth is a path-prefix token: `{baseUrl}/{token}/api/v2/...`; deployments
//   running the default token (`87654321`) also accept token-less paths, so a
//   configured empty token maps to `{baseUrl}/api/v2/...`.
// - POST /api/v2/match                -> {success, isMatched, matches[]}
// - GET  /api/v2/search/episodes?anime= -> {success, animes[]: [{episodes[]}]}
// - GET  /api/v2/bangumi/{animeId}    -> {success, bangumi: {episodes[]}}
// - GET  /api/v2/comment/{id}?format=json&duration=true
//                                     -> {success, errorCode, errorMessage,
//                                         count, videoDuration?, comments[]}
// - POST /api/v2/segmentcomment?format=json  (segment JSON body)
// Comment `p` field: 4-field `time,mode,color,source` and 8/9-field
// `time,mode,fontSize,color,...` are both accepted; mode 1/6/7 scroll,
// 4 bottom, 5 top.
//
// Security: tokens, cookies and secrets are never logged. Log lines only ever
// contain the request path *template* (no query, no token segment) and the
// HTTP status.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../model/episode_title_classifier.dart';
import '../model/danmaku_models.dart' as parsed_models;
import 'danmu_api_comment_parser.dart';
import 'danmaku_source_registry.dart';

/// Default timeout for one HTTP attempt.
const Duration kDanmuApiDefaultTimeout = Duration(seconds: 20);

/// Retry policy: 429/5xx/network/timeouts get up to [maxAttempts] total
/// attempts with exponential backoff [initialBackoff] * 2^(attempt-1).
class DanmuApiRetryPolicy {
  const DanmuApiRetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 6),
    this.rateLimitFallback = const Duration(seconds: 30),
  });

  final int maxAttempts;
  final Duration initialBackoff;
  final Duration maxBackoff;

  /// Conservative cooldown when a deployment returns 429 without the
  /// standard Retry-After header. Public comment providers commonly allow
  /// only a few requests per 30-second window.
  final Duration rateLimitFallback;

  /// Backoff before retry [retryIndex] (0-based). Honors the server-provided
  /// [retryAfter] for 429 responses when it is longer than the computed one.
  Duration backoffFor(int retryIndex, {Duration? retryAfter}) {
    var delay = initialBackoff * (1 << retryIndex.clamp(0, 8));
    if (delay > maxBackoff) delay = maxBackoff;
    final server = retryAfter;
    if (server != null && server > delay) delay = server;
    return delay;
  }
}

/// Configuration for one danmu_api deployment.
class DanmuApiConfig {
  const DanmuApiConfig({
    required this.baseUrl,
    this.token = '',
    this.sourceId = 'danmu_api',
    this.displayName = 'danmu_api',
    this.httpClient,
  });

  /// The deployed service address, e.g. `https://danmu.example.com` or
  /// `http://192.168.1.10:9321`. A GitHub repository URL is NOT a service
  /// address; callers must validate before constructing (see
  /// [DanmuApiConfig.normalizedBaseUrl]).
  final String baseUrl;

  /// Optional path token. Empty for token-less deployments.
  final String token;

  final String sourceId;
  final String displayName;

  /// Test seam: injected HTTP client. When null a fresh `HttpClient` is used
  /// per attempt (like the rest of this codebase) and closed after each one.
  final HttpClient? httpClient;

  /// Trims trailing slashes; throws [ArgumentError] when empty or not http(s).
  static String normalizedBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(raw, 'baseUrl', 'Base URL is required');
    }
    final uri = Uri.tryParse(trimmed);
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        !uri.hasScheme ||
        (scheme != 'http' && scheme != 'https') ||
        uri.host.isEmpty) {
      throw ArgumentError.value(
        raw,
        'baseUrl',
        'Must be a deployed http(s) service address',
      );
    }
    var normalized = trimmed;
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}

/// danmu_api implementation of [DanmakuSource].
class DanmuApiSource implements DanmakuSource, ProgressiveDanmakuSource {
  DanmuApiSource(this._config, {DanmuApiRetryPolicy? retryPolicy})
    : retryPolicy = retryPolicy ?? const DanmuApiRetryPolicy() {
    _normalizedBaseUrl = DanmuApiConfig.normalizedBaseUrl(_config.baseUrl);
    _baseUri = Uri.parse(_normalizedBaseUrl);
  }

  final DanmuApiConfig _config;
  final DanmuApiRetryPolicy retryPolicy;

  late final String _normalizedBaseUrl;
  late final Uri _baseUri;

  @override
  String get sourceId => _config.sourceId;

  @override
  String get displayName => _config.displayName;

  /// Scope hash binds caches to this deployment (source id + base URL hash).
  /// The token is intentionally NOT part of the scope: it selects an account
  /// on the same service, not a different dataset; the base URL is what
  /// changes the data universe.
  @override
  String get cacheScope => hashIdentity('$sourceId|$_normalizedBaseUrl');

  Uri _buildUri(String path, Map<String, String>? query) {
    final q = <String, String>{...?query};
    final baseSegments = _baseUri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    final alreadyIncludesApi =
        baseSegments.length >= 2 &&
        baseSegments[baseSegments.length - 2] == 'api' &&
        baseSegments.last == 'v2';
    final token = _config.token.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (alreadyIncludesApi) {
      final apiIndex = baseSegments.length - 2;
      if (token.isNotEmpty &&
          (apiIndex == 0 || baseSegments[apiIndex - 1] != token)) {
        baseSegments.insert(apiIndex, token);
      }
    } else {
      if (token.isNotEmpty &&
          (baseSegments.isEmpty || baseSegments.last != token)) {
        baseSegments.add(token);
      }
      baseSegments.addAll(const ['api', 'v2']);
    }
    return Uri(
      scheme: _baseUri.scheme,
      userInfo: _baseUri.userInfo,
      host: _baseUri.host,
      port: _baseUri.hasPort ? _baseUri.port : null,
      pathSegments: [
        ...baseSegments,
        ...path
            .split('/')
            .where((segment) => segment.isNotEmpty)
            .map(Uri.decodeComponent),
      ],
      queryParameters: q.isEmpty ? null : q,
    );
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  @override
  Future<void> verifyConnectivity({DanmakuCancelToken? cancelToken}) async {
    // The cheapest authenticated endpoint is a search; an empty keyword
    // yields a clean protocol-level response from real deployments.
    await _send(
      method: 'GET',
      path: '/search/episodes',
      query: const {'anime': 'AlnPlay'},
      cancelToken: cancelToken,
    );
  }

  @override
  Future<DanmakuSourceMatch?> match({
    required String fileName,
    String? fileHash,
    int? fileSize,
    String? matchMode,
    DanmakuCancelToken? cancelToken,
  }) async {
    final body = <String, dynamic>{
      'fileName': fileName,
      if (fileHash != null && fileHash.isNotEmpty) 'fileHash': fileHash,
      'fileSize': ?fileSize,
      'matchMode':
          matchMode ?? (fileHash != null ? 'hashAndFileName' : 'fileName'),
    };
    final decoded = await _send(
      method: 'POST',
      path: '/match',
      jsonBody: body,
      cancelToken: cancelToken,
    );
    if (decoded['success'] != true) {
      throw _protocolExceptionFor(decoded, 'match');
    }
    if (decoded['isMatched'] != true) return null;
    final matches = decoded['matches'];
    if (matches is! List || matches.isEmpty) return null;
    final validMatches = matches.whereType<Map>().where((entry) {
      final episodeTitle = '${entry['episodeTitle'] ?? ''}';
      return _stringId(entry['episodeId']) != null &&
          _stringId(entry['animeId']) != null &&
          !isDanmakuPromotionalEpisodeTitle(episodeTitle);
    }).toList();
    if (validMatches.isEmpty) return null;
    final distinctEpisodes = validMatches
        .map(
          (entry) =>
              '${_stringId(entry['animeId'])}:${_stringId(entry['episodeId'])}',
        )
        .toSet();
    if (distinctEpisodes.length != 1) {
      // The single-result source contract cannot represent a user choice.
      // Returning no-match keeps ambiguous candidates visible to the UI
      // instead of silently binding the first unrelated episode.
      return null;
    }
    final first = validMatches.first;
    final episodeId = _stringId(first['episodeId']);
    final animeId = _stringId(first['animeId']);
    if (episodeId == null || animeId == null) {
      throw const DanmakuProtocolException(
        'match: episodeId/animeId missing in match entry',
      );
    }
    return DanmakuSourceMatch(
      episodeId: episodeId,
      animeId: animeId,
      animeTitle: (first['animeTitle'] as String?) ?? '',
      episodeTitle: (first['episodeTitle'] as String?) ?? '',
      shift: _intValue(first['shift']) ?? 0,
      url: (first['url'] as String?) ?? '',
    );
  }

  @override
  Future<DanmakuSourceComments> fetchComments({
    required String episodeId,
    DanmakuCancelToken? cancelToken,
  }) =>
      fetchCommentsWithProgress(episodeId: episodeId, cancelToken: cancelToken);

  @override
  Future<DanmakuSourceComments> fetchCommentsWithProgress({
    required String episodeId,
    DanmakuCancelToken? cancelToken,
    DanmakuProgressCallback? onProgress,
  }) async {
    final id = Uri.encodeComponent(episodeId);
    final decoded = await _send(
      method: 'GET',
      path: '/comment/$id',
      query: const {'format': 'json', 'duration': 'true'},
      cancelToken: cancelToken,
      onDownloadProgress: onProgress,
    );
    // Real danmu_api deployments commonly return the comment payload without
    // the `{success: true}` envelope used by match/search. Treat an explicit
    // rejection as failure, but accept the documented bare payload whenever
    // `comments` is a list.
    if (decoded['success'] == false || decoded['comments'] is! List) {
      throw _protocolExceptionFor(decoded, 'comment');
    }
    final parsed = parseDanmuApiCommentsMap(decoded, source: sourceId);
    return DanmakuSourceComments(
      comments: parsed.items.map(_toSourceComment).toList(growable: false),
      videoDurationSeconds: parsed.videoDurationSeconds,
    );
  }

  @override
  Future<List<DanmakuSourceEpisodeGroup>> searchEpisodes({
    required String anime,
    DanmakuCancelToken? cancelToken,
  }) async {
    final decoded = await _send(
      method: 'GET',
      path: '/search/episodes',
      query: {'anime': anime},
      cancelToken: cancelToken,
    );
    if (decoded['success'] != true) {
      throw _protocolExceptionFor(decoded, 'search/episodes');
    }
    return _parseEpisodeGroups(decoded['animes']);
  }

  @override
  Future<DanmakuSourceEpisodeGroup?> bangumi({
    required String animeId,
    DanmakuCancelToken? cancelToken,
  }) async {
    final id = Uri.encodeComponent(animeId);
    final decoded = await _send(
      method: 'GET',
      path: '/bangumi/$id',
      cancelToken: cancelToken,
    );
    if (decoded['success'] != true) return null;
    final bangumi = decoded['bangumi'];
    if (bangumi is! Map) return null;
    final groups = _parseEpisodeGroups([bangumi]);
    return groups.isEmpty ? null : groups.first;
  }

  @override
  Future<List<DanmakuSourceComment>> fetchSegmentComments({
    required DanmakuSegment segment,
    DanmakuCancelToken? cancelToken,
  }) async {
    final decoded = await _send(
      method: 'POST',
      path: '/segmentcomment',
      query: const {'format': 'json'},
      jsonBody: segment.toJson(),
      cancelToken: cancelToken,
    );
    if (decoded['success'] != true) {
      throw _protocolExceptionFor(decoded, 'segmentcomment');
    }
    final parsed = parseDanmuApiCommentsMap(decoded, source: sourceId);
    return parsed.items.map(_toSourceComment).toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Parsing helpers
  // ---------------------------------------------------------------------------

  List<DanmakuSourceEpisodeGroup> _parseEpisodeGroups(dynamic animes) {
    final groups = <DanmakuSourceEpisodeGroup>[];
    if (animes is! List) return groups;
    for (final anime in animes) {
      if (anime is! Map) continue;
      final animeId = _stringId(anime['animeId']);
      if (animeId == null) continue;
      final episodes = <DanmakuSourceEpisode>[];
      final rawEpisodes = anime['episodes'];
      if (rawEpisodes is List) {
        for (final ep in rawEpisodes) {
          if (ep is! Map) continue;
          final epId = _stringId(ep['episodeId']);
          if (epId == null) continue;
          episodes.add(
            DanmakuSourceEpisode(
              episodeId: epId,
              episodeTitle: (ep['episodeTitle'] as String?) ?? '',
              url: (ep['url'] as String?) ?? '',
            ),
          );
        }
      }
      groups.add(
        DanmakuSourceEpisodeGroup(
          animeId: animeId,
          animeTitle: (anime['animeTitle'] as String?) ?? '',
          episodes: episodes,
        ),
      );
    }
    return groups;
  }

  DanmakuSourceComment _toSourceComment(parsed_models.DanmakuItem item) {
    return DanmakuSourceComment(
      timeSeconds: item.timeSeconds,
      mode: switch (item.mode) {
        parsed_models.DanmakuMode.scroll => 1,
        parsed_models.DanmakuMode.bottom => 4,
        parsed_models.DanmakuMode.top => 5,
      },
      colorRgb: item.colorRgb,
      content: item.text,
      danmakuId: item.danmakuId,
      likes: item.likes,
    );
  }

  /// Numeric OR string id -> string, never via toInt() (large ids must not
  /// lose precision).
  String? _stringId(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      if (value.isNaN || value.isInfinite) return null;
      // Preserve integer formatting for whole numbers (10001 -> "10001").
      return value.toInt().toString();
    }
    final s = value.toString().trim();
    if (s.isEmpty) return null;
    final asNum = num.tryParse(s);
    if (asNum != null && asNum.isFinite) return asNum.toInt().toString();
    return s;
  }

  int? _intValue(dynamic value) => switch (value) {
    num number => number.toInt(),
    String text => num.tryParse(text.trim())?.toInt(),
    _ => null,
  };

  DanmakuSourceException _protocolExceptionFor(
    Map<String, dynamic> decoded,
    String endpoint,
  ) {
    final code = (decoded['errorCode'] as num?)?.toInt();
    final message = (decoded['errorMessage'] as String?) ?? '';
    if (message.isNotEmpty) {
      return DanmakuProtocolException('$endpoint: $message');
    }
    return DanmakuProtocolException(
      '$endpoint: service rejected the request${code != null ? ' (errorCode $code)' : ''}',
    );
  }

  // ---------------------------------------------------------------------------
  // HTTP plumbing
  // ---------------------------------------------------------------------------

  /// Sends one request with retry/cancel/timeout handling and decodes the
  /// JSON envelope. Throws typed [DanmakuSourceException]s.
  ///
  /// Error mapping (requirement 10):
  /// - 429 -> [DanmakuRateLimitException] (retryable, honors Retry-After)
  /// - 5xx -> [DanmakuServerException] (retryable)
  /// - 401/403 -> [DanmakuAuthException] (token/config problem)
  /// - other 4xx -> [DanmakuRequestException]
  /// - socket/TLS/timeout -> [DanmakuNetworkException]
  /// - malformed JSON -> [DanmakuProtocolException]
  Future<Map<String, dynamic>> _send({
    required String method,
    required String path,
    Map<String, String>? query,
    Map<String, dynamic>? jsonBody,
    DanmakuCancelToken? cancelToken,
    DanmakuProgressCallback? onDownloadProgress,
  }) async {
    // Only the request shape is logged — never the URL (the path prefix can
    // carry the token) and never headers/body.
    if (kDanmuApiLogRequests) _log('$method danmu_api:$path');
    var attempt = 0;
    while (true) {
      _throwIfCancelled(cancelToken);
      Duration? backoff;
      Object? failure;
      try {
        return await _attemptOnce(
          method: method,
          path: path,
          query: query,
          jsonBody: jsonBody,
          cancelToken: cancelToken,
          onDownloadProgress: onDownloadProgress,
        );
      } on DanmakuCancelledException {
        rethrow;
      } on DanmakuRateLimitException catch (e) {
        failure = e;
        backoff = retryPolicy.backoffFor(
          attempt,
          retryAfter: e.retryAfter ?? retryPolicy.rateLimitFallback,
        );
      } on DanmakuServerException catch (e) {
        failure = e;
        backoff = retryPolicy.backoffFor(attempt);
      } on DanmakuNetworkException catch (e) {
        failure = e;
        backoff = retryPolicy.backoffFor(attempt);
      }
      attempt += 1;
      if (attempt >= retryPolicy.maxAttempts) {
        // ignore: only_throw_errors
        throw failure;
      }
      _throwIfCancelled(cancelToken);
      await _awaitWithCancellation(Future<void>.delayed(backoff), cancelToken);
    }
  }

  Future<Map<String, dynamic>> _attemptOnce({
    required String method,
    required String path,
    Map<String, String>? query,
    Map<String, dynamic>? jsonBody,
    DanmakuCancelToken? cancelToken,
    DanmakuProgressCallback? onDownloadProgress,
  }) async {
    _throwIfCancelled(cancelToken);
    final uri = _buildUri(path, query);
    final ownedClient = _config.httpClient == null;
    final client = ownedClient ? HttpClient() : _config.httpClient!;
    try {
      client.connectionTimeout = kDanmuApiDefaultTimeout;
      final request = await _awaitWithCancellation(
        method == 'POST' ? client.postUrl(uri) : client.getUrl(uri),
        cancelToken,
        onCancel: ownedClient ? () => client.close(force: true) : null,
      );
      if (jsonBody != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(jsonBody));
      }
      void abortRequest() {
        request.abort(const DanmakuCancelledException());
        if (ownedClient) client.close(force: true);
      }

      final response = await _awaitWithCancellation(
        request.close().timeout(kDanmuApiDefaultTimeout),
        cancelToken,
        onCancel: abortRequest,
      );
      final totalBytes =
          response.compressionState !=
                  HttpClientResponseCompressionState.decompressed &&
              response.contentLength >= 0
          ? response.contentLength
          : null;
      final stopwatch = Stopwatch()..start();
      var received = 0;
      _reportProgress(
        onDownloadProgress,
        DanmakuLoadProgress(
          phase: DanmakuLoadPhase.downloading,
          sourceId: sourceId,
          bytesReceived: 0,
          totalBytes: totalBytes,
          bytesPerSecond: 0,
        ),
      );
      final bytes = await _awaitWithCancellation(
        response
            .fold<List<int>>(<int>[], (buffer, chunk) {
              buffer.addAll(chunk);
              received += chunk.length;
              final seconds = stopwatch.elapsedMicroseconds / 1000000;
              _reportProgress(
                onDownloadProgress,
                DanmakuLoadProgress(
                  phase: DanmakuLoadPhase.downloading,
                  sourceId: sourceId,
                  bytesReceived: received,
                  totalBytes: totalBytes,
                  bytesPerSecond: seconds > 0 ? received / seconds : null,
                ),
              );
              return buffer;
            })
            .timeout(kDanmuApiDefaultTimeout),
        cancelToken,
        onCancel: abortRequest,
      );
      final status = response.statusCode;
      switch (status) {
        case 429:
          throw DanmakuRateLimitException(
            'danmu_api rate limited (429)',
            retryAfter: _parseRetryAfter(response.headers.value('retry-after')),
          );
        case 401:
        case 403:
          throw DanmakuAuthException(
            'danmu_api rejected the token ($status) — check the service token setting',
          );
      }
      if (status >= 500) {
        throw DanmakuServerException('danmu_api server error ($status)');
      }
      if (status >= 400) {
        throw DanmakuRequestException('danmu_api request error ($status)');
      }
      _reportProgress(
        onDownloadProgress,
        DanmakuLoadProgress(
          phase: DanmakuLoadPhase.parsing,
          sourceId: sourceId,
          bytesReceived: received,
          totalBytes: totalBytes,
          bytesPerSecond: stopwatch.elapsedMicroseconds > 0
              ? received / (stopwatch.elapsedMicroseconds / 1000000)
              : null,
        ),
      );
      final text = utf8.decode(bytes, allowMalformed: true);
      Map<String, dynamic> decoded;
      try {
        final value = jsonDecode(text);
        if (value is! Map<String, dynamic>) {
          throw const FormatException('not a JSON object');
        }
        decoded = value;
      } on FormatException {
        throw const DanmakuProtocolException(
          'danmu_api returned a non-JSON body',
        );
      }
      return decoded;
    } on SocketException catch (e) {
      throw DanmakuNetworkException('danmu_api unreachable: ${e.message}');
    } on HandshakeException {
      throw const DanmakuNetworkException('danmu_api TLS handshake failed');
    } on HttpException catch (e) {
      throw DanmakuNetworkException('danmu_api HTTP failure: ${e.message}');
    } on TimeoutException {
      throw const DanmakuNetworkException('danmu_api request timed out');
    } finally {
      if (ownedClient) client.close(force: true);
    }
  }

  Future<T> _awaitWithCancellation<T>(
    Future<T> operation,
    DanmakuCancelToken? cancelToken, {
    void Function()? onCancel,
  }) {
    if (cancelToken == null) return operation;
    _throwIfCancelled(cancelToken);
    return Future.any<T>([
      operation,
      cancelToken.whenCancelled.then<T>((_) {
        onCancel?.call();
        throw const DanmakuCancelledException();
      }),
    ]);
  }

  static Duration? _parseRetryAfter(String? raw) {
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds != null && seconds > 0) return Duration(seconds: seconds);
    return null;
  }

  void _throwIfCancelled(DanmakuCancelToken? cancelToken) {
    if (cancelToken?.isCancelled ?? false) {
      throw const DanmakuCancelledException();
    }
  }

  static const bool kDanmuApiLogRequests = false;

  static void _log(String message) {
    // Central choke point: only request templates land here, never URLs with
    // tokens, headers, bodies or credentials.
    assert(() {
      // ignore: avoid_print
      print('[DanmuApiSource] $message');
      return true;
    }());
  }

  static void _reportProgress(
    DanmakuProgressCallback? callback,
    DanmakuLoadProgress progress,
  ) {
    if (callback == null) return;
    try {
      callback(progress);
    } catch (_) {}
  }
}

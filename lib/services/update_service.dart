import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String alnPlayReleaseUrl =
    'https://github.com/ADBC123456/AlnPlay/releases/latest';

enum UpdateStatus {
  updateAvailable,
  upToDate,
  notFound,
  rateLimited,
  networkError,
  invalidResponse,
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.url,
    this.publishedAt,
  });
  final String version;
  final String notes;
  final String url;
  final DateTime? publishedAt;
}

class UpdateResult {
  const UpdateResult(this.status, {this.release, this.error});
  final UpdateStatus status;
  final UpdateInfo? release;
  final Object? error;
  bool get hasUpdate =>
      status == UpdateStatus.updateAvailable && release != null;
}

typedef UpdateRequest =
    Future<UpdateHttpResponse> Function(Uri uri, Map<String, String> headers);

class UpdateHttpResponse {
  const UpdateHttpResponse(
    this.statusCode,
    this.body, {
    this.etag,
    this.retryAfter,
  });
  final int statusCode;
  final String body;
  final String? etag;
  final Duration? retryAfter;
}

/// Checks only the public latest stable release of the AlnPlay repository.
/// Network errors are deliberately returned as state rather than thrown so a
/// startup check can never affect app startup.
class UpdateService {
  UpdateService({
    UpdateRequest? request,
    Future<String?> Function()? installedVersion,
  }) : _request = request ?? _defaultRequest,
       _installedVersion = installedVersion ?? _nativeVersion;

  static const _etagKey = 'dreamplayer.update.etag';
  static const _checkedAtKey = 'dreamplayer.update.checkedAtMs';
  static const _cachedReleaseKey = 'dreamplayer.update.cachedRelease';
  static const _notifiedVersionKey = 'dreamplayer.update.notifiedVersion';
  static const _retryUntilKey = 'dreamplayer.update.retryUntilMs';
  static const _lastStatusKey = 'dreamplayer.update.lastStatus';
  static const _channel = MethodChannel('dreamplayer/app_info');
  static final Uri _latestUri = Uri.parse(
    'https://api.github.com/repos/ADBC123456/AlnPlay/releases/latest',
  );

  final UpdateRequest _request;
  final Future<String?> Function() _installedVersion;

  static Future<UpdateHttpResponse> _defaultRequest(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      return await () async {
        final req = await client.getUrl(uri);
        headers.forEach(req.headers.set);
        final response = await req.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const FormatException('GitHub response exceeds 1 MiB');
          }
          bytes.addAll(chunk);
        }
        return UpdateHttpResponse(
          response.statusCode,
          utf8.decode(bytes),
          etag: response.headers.value('etag'),
          retryAfter: _retryAfter(response.headers),
        );
      }().timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }

  static Future<String?> _nativeVersion() async {
    try {
      return await _channel.invokeMethod<String>('version');
    } catch (_) {
      return null;
    }
  }

  /// Automatic checks are once per 24 hours. [force] is used by the settings
  /// tile and bypasses that throttle while retaining conditional ETag requests.
  Future<UpdateResult> check({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final retryUntil = prefs.getInt(_retryUntilKey) ?? 0;
    if (now < retryUntil) return const UpdateResult(UpdateStatus.rateLimited);
    final previous = prefs.getInt(_checkedAtKey) ?? 0;
    if (!force && now - previous < const Duration(hours: 24).inMilliseconds) {
      final cached = _decodeCached(prefs.getString(_cachedReleaseKey));
      final savedStatus = UpdateStatus.values
          .where((status) => status.name == prefs.getString(_lastStatusKey))
          .firstOrNull;
      if (savedStatus != null &&
          savedStatus != UpdateStatus.upToDate &&
          savedStatus != UpdateStatus.updateAvailable) {
        return UpdateResult(savedStatus);
      }
      if (cached == null) {
        return const UpdateResult(UpdateStatus.invalidResponse);
      }
      return _compareWithInstalled(cached);
    }
    final headers = <String, String>{
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'AlnPlay-update-check',
    };
    final etag = prefs.getString(_etagKey);
    if (etag != null && etag.isNotEmpty) headers['If-None-Match'] = etag;
    try {
      final response = await _request(_latestUri, headers);
      await prefs.setInt(_checkedAtKey, now);
      await prefs.setString(_lastStatusKey, UpdateStatus.invalidResponse.name);
      if (response.statusCode == 304) {
        final cached = _decodeCached(prefs.getString(_cachedReleaseKey));
        final result = cached == null
            ? const UpdateResult(UpdateStatus.invalidResponse)
            : await _compareWithInstalled(cached);
        await prefs.setString(_lastStatusKey, result.status.name);
        return result;
      }
      if (response.statusCode == 404) {
        await prefs.setString(_lastStatusKey, UpdateStatus.notFound.name);
        return const UpdateResult(UpdateStatus.notFound);
      }
      if (response.statusCode == 403 || response.statusCode == 429) {
        final wait = response.retryAfter ?? const Duration(minutes: 1);
        await prefs.setInt(_retryUntilKey, now + wait.inMilliseconds);
        await prefs.setString(_lastStatusKey, UpdateStatus.rateLimited.name);
        return const UpdateResult(UpdateStatus.rateLimited);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await prefs.setString(_lastStatusKey, UpdateStatus.networkError.name);
        return const UpdateResult(UpdateStatus.networkError);
      }
      final json = jsonDecode(response.body);
      if (json is! Map || json['draft'] == true || json['prerelease'] == true) {
        return const UpdateResult(UpdateStatus.invalidResponse);
      }
      final tag = json['tag_name'];
      if (tag is! String || !_isStableVersion(tag)) {
        return const UpdateResult(UpdateStatus.invalidResponse);
      }
      final releaseUrl = json['html_url'] as String?;
      if (releaseUrl == null) {
        return const UpdateResult(UpdateStatus.invalidResponse);
      }
      if (!_isReleaseUrl(releaseUrl, tag)) {
        // Do not open arbitrary URLs returned by an API response.
        return const UpdateResult(UpdateStatus.invalidResponse);
      }
      final info = UpdateInfo(
        version: tag,
        notes: (json['body'] as String?) ?? '',
        url: releaseUrl,
        publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
      );
      await prefs.setString(
        _cachedReleaseKey,
        jsonEncode({
          'version': info.version,
          'notes': info.notes,
          'url': info.url,
          'publishedAt': info.publishedAt?.toIso8601String(),
        }),
      );
      if (response.etag != null) {
        await prefs.setString(_etagKey, response.etag!);
      }
      final result = await _compareWithInstalled(info);
      await prefs.setString(_lastStatusKey, result.status.name);
      return result;
    } on SocketException catch (e) {
      await prefs.setInt(_checkedAtKey, now);
      await prefs.setString(_lastStatusKey, UpdateStatus.networkError.name);
      return UpdateResult(UpdateStatus.networkError, error: e);
    } on TimeoutException catch (e) {
      await prefs.setInt(_checkedAtKey, now);
      await prefs.setString(_lastStatusKey, UpdateStatus.networkError.name);
      return UpdateResult(UpdateStatus.networkError, error: e);
    } on FormatException catch (e) {
      await prefs.setInt(_checkedAtKey, now);
      await prefs.setString(_lastStatusKey, UpdateStatus.invalidResponse.name);
      return UpdateResult(UpdateStatus.invalidResponse, error: e);
    } catch (e) {
      await prefs.setInt(_checkedAtKey, now);
      await prefs.setString(_lastStatusKey, UpdateStatus.networkError.name);
      return UpdateResult(UpdateStatus.networkError, error: e);
    }
  }

  Future<UpdateResult> _compareWithInstalled(UpdateInfo release) async {
    final installed = await _installedVersion();
    if (!_isStableVersion(release.version) ||
        installed == null ||
        !_isStableVersion(installed)) {
      return const UpdateResult(UpdateStatus.invalidResponse);
    }
    return compareVersions(release.version, installed) > 0
        ? UpdateResult(UpdateStatus.updateAvailable, release: release)
        : UpdateResult(UpdateStatus.upToDate, release: release);
  }

  static UpdateInfo? _decodeCached(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['version'] is! String) return null;
      final url = j['url'] as String?;
      if (url == null) return null;
      if (!_isStableVersion(j['version'] as String) ||
          !_isReleaseUrl(url, j['version'] as String)) {
        return null;
      }
      return UpdateInfo(
        version: j['version'] as String,
        notes: j['notes'] as String? ?? '',
        url: url,
        publishedAt: DateTime.tryParse(j['publishedAt'] as String? ?? ''),
      );
    } catch (_) {
      return null;
    }
  }

  /// Compares stable numeric SemVer components; a leading `v` and build data
  /// are ignored. Missing components are zero (1.10 > 1.9).
  static int compareVersions(String a, String b) {
    List<int> parts(String value) => value
        .trim()
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split('+')
        .first
        .split('-')
        .first
        .split('.')
        .map((x) => int.tryParse(x) ?? 0)
        .toList();
    final aa = parts(a), bb = parts(b);
    for (var i = 0; i < (aa.length > bb.length ? aa.length : bb.length); i++) {
      final c = (i < aa.length ? aa[i] : 0).compareTo(
        i < bb.length ? bb[i] : 0,
      );
      if (c != 0) return c;
    }
    return 0;
  }

  static bool _isStableVersion(String value) =>
      value.length <= 128 &&
      RegExp(
        r'^[vV]?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
      ).hasMatch(value.trim());

  static bool _isReleaseUrl(String url, String tag) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        !uri.hasPort &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.pathSegments.length == 5 &&
        uri.pathSegments[0] == 'ADBC123456' &&
        uri.pathSegments[1] == 'AlnPlay' &&
        uri.pathSegments[2] == 'releases' &&
        uri.pathSegments[3] == 'tag' &&
        uri.pathSegments[4] == tag;
  }

  Future<String?> get installedVersion => _installedVersion();

  Future<bool> shouldNotify(UpdateInfo release) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_notifiedVersionKey) != release.version;
  }

  Future<void> markNotified(UpdateInfo release) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_notifiedVersionKey, release.version);
  }

  static Duration? _retryAfter(HttpHeaders headers) {
    final value = headers.value('retry-after');
    final seconds = value == null ? null : int.tryParse(value);
    if (seconds != null) return Duration(seconds: seconds.clamp(0, 86400));
    if (value != null) {
      try {
        final wait = HttpDate.parse(value).difference(DateTime.now());
        return Duration(seconds: wait.inSeconds.clamp(0, 86400));
      } on FormatException {
        /* Fall through to GitHub's epoch header. */
      }
    }
    final reset = int.tryParse(headers.value('x-ratelimit-reset') ?? '');
    if (reset == null) return null;
    final secondsUntil = reset - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Duration(seconds: secondsUntil.clamp(0, 86400));
  }
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';
import '../library/title_playback_preferences.dart';
import '../library/unified_library_service.dart';
import 'webdav_client.dart';

/// A video the user was watching: keeps enough metadata (title, source,
/// duration) plus the resume position so the home library can show a
/// "Continue watching" row that resumes mid-way.
class ContinueWatchingEntry {
  const ContinueWatchingEntry({
    required this.video,
    required this.position,
    required this.updatedAt,
  });

  final VideoItem video;
  final Duration position;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'video': video.toJson(),
    'positionMs': position.inMilliseconds,
    'updatedAtMs': updatedAt.millisecondsSinceEpoch,
  };

  factory ContinueWatchingEntry.fromJson(Map<String, dynamic> json) {
    return ContinueWatchingEntry(
      video: VideoItem.fromJson((json['video'] as Map).cast<String, dynamic>()),
      position: Duration(
        milliseconds: (json['positionMs'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

/// Persists the continue-watching list (shared_preferences JSON), keyed by the
/// same stable source key ResumeStore uses (explicit resumeKey, else path, else
/// URI).
/// Wraps [ChangeNotifier] so the static store can fire the (protected)
/// `notifyListeners` from its own method.
class StoreChangeNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

class ContinueWatchingStore {
  ContinueWatchingStore._();

  static const String _prefsKey = 'dreamplayer.continueWatching';

  /// Fires whenever the persisted list changes (a save or a remove), so the
  /// home screen can reload.
  static final StoreChangeNotifier changes = StoreChangeNotifier();

  static String keyFor(VideoItem video) =>
      video.resumeKey ?? video.path ?? video.uri ?? '';

  static Future<List<ContinueWatchingEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return <ContinueWatchingEntry>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final entries = list
          .map((e) => ContinueWatchingEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      return await Future.wait(entries.map(_restoreNetworkAccess));
    } catch (_) {
      return const [];
    }
  }

  static Future<ContinueWatchingEntry> _restoreNetworkAccess(
    ContinueWatchingEntry entry,
  ) async {
    final video = entry.video;
    final key = video.resumeKey ?? '';
    if (video.playbackSource != PlaybackSource.webdav &&
        !key.startsWith('webdav_')) {
      return entry;
    }
    try {
      final servers = await WebDavClient.instance.listServers();
      WebDavServer? server;
      final savedId = video.webdavServerId;
      for (final candidate in servers) {
        if ((savedId != null && candidate.id == savedId) ||
            key.startsWith('webdav_${candidate.id}')) {
          server = candidate;
          break;
        }
      }
      if (server == null) return entry;
      String authorization = '';
      try {
        authorization = await WebDavClient.instance.authorizationHeader(
          server.id,
        );
      } catch (_) {
        // Anonymous WebDAV servers legitimately have no Authorization header.
      }
      final restored = video.withNetworkAccess(
        httpHeaders: authorization.isEmpty
            ? const {}
            : {'Authorization': authorization},
        webdavServerId: server.id,
        allowSelfSigned: server.allowSelfSigned,
      );
      return ContinueWatchingEntry(
        video: restored,
        position: entry.position,
        updatedAt: entry.updatedAt,
      );
    } catch (_) {
      return entry;
    }
  }

  static Future<void> _writes = Future.value();

  static Future<void> _serial(Future<void> Function() work) {
    final operation = _writes.then((_) => work());
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static Future<void> clearAll() => _serial(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    changes.notify();
  });

  static Future<void> save(VideoItem video, Duration position) => _serial(
    () async {
      if (position.inMilliseconds < 10000) return;
      final key = keyFor(video);
      if (key.isEmpty) return;
      // Keep non-sensitive source identity and media metadata. VideoItem.toJson
      // intentionally omits httpHeaders, so WebDAV credentials are rehydrated
      // from the native encrypted store by [load].
      final entryVideo = video.withPlaybackInfo(duration: video.duration);
      final all = await load();
      all.removeWhere((e) => keyFor(e.video) == key);
      all.insert(
        0,
        ContinueWatchingEntry(
          video: entryVideo,
          position: position,
          updatedAt: DateTime.now(),
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(all.map((e) => e.toJson()).toList()),
      );
      final file = UnifiedLibraryService.instance.snapshot.files.values
          .where((file) => file.legacyResumeKey == key)
          .firstOrNull;
      if (file?.titleId != null) {
        await TitlePlaybackPreferences.save(
          titleId: file!.titleId!,
          lastPlayedFileId: file.id,
          lastPlayedEpisodeId: file.episodeId,
          playedAt: all.first.updatedAt,
        );
      }
      changes.notify();
    },
  );

  static Future<void> remove(String key) => _serial(() async {
    if (key.isEmpty) return;
    final all = await load();
    all.removeWhere((e) => keyFor(e.video) == key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(all.map((e) => e.toJson()).toList()),
    );
    changes.notify();
  });
}

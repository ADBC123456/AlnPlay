import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models/library_models.dart';

class TitlePlaybackPreferences {
  TitlePlaybackPreferences._();

  static const String _key = 'dreamplayer.titlePlaybackPreferences';
  static Future<void> _writeTail = Future<void>.value();

  static Future<TitlePlaybackPreference?> load(String titleId) async {
    final all = await _loadAll();
    final json = all[titleId];
    if (json is! Map<String, dynamic>) return null;
    return TitlePlaybackPreference(
      titleId: titleId,
      preferredSourceId: json['preferredSourceId'] as String?,
      lastPlayedFileId: json['lastPlayedFileId'] as String?,
      lastPlayedEpisodeId: json['lastPlayedEpisodeId'] as String?,
      lastPlayedAt: json['lastPlayedAtMs'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['lastPlayedAtMs'] as num).toInt(),
            )
          : null,
    );
  }

  static Future<void> save({
    required String titleId,
    String? preferredSourceId,
    String? lastPlayedFileId,
    String? lastPlayedEpisodeId,
    DateTime? playedAt,
  }) => _enqueue(() async {
    final prefs = await SharedPreferences.getInstance();
    final all = await _loadAll();
    final current = all[titleId] is Map
        ? (all[titleId] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    all[titleId] = {
      ...current,
      'preferredSourceId': ?preferredSourceId,
      'lastPlayedFileId': ?lastPlayedFileId,
      'lastPlayedEpisodeId': ?lastPlayedEpisodeId,
      if (lastPlayedFileId != null || lastPlayedEpisodeId != null)
        'lastPlayedAtMs': (playedAt ?? DateTime.now()).millisecondsSinceEpoch,
    };
    await prefs.setString(_key, jsonEncode(all));
  });

  static Future<void> _enqueue(Future<void> Function() mutation) {
    final operation = _writeTail.then((_) => mutation());
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _writeTail = settled;
    return () async {
      try {
        await operation;
      } finally {
        await settled;
      }
    }();
  }

  static Future<Map<String, dynamic>> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }
}

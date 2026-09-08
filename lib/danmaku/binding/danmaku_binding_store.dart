import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../scraper/scrape_state.dart';

/// A durable association between one playable file and one remote danmaku
/// episode. Bindings are deliberately independent from the comment cache:
/// clearing or expiring downloaded comments must not discard a user's choice.
class DanmakuBinding {
  const DanmakuBinding({
    required this.sourceId,
    required this.sourceBaseUrl,
    required this.videoIdentity,
    required this.ref,
    required this.updatedAtMs,
    this.manual = true,
  });

  final String sourceId;
  final String sourceBaseUrl;
  final String videoIdentity;
  final DanmakuEpisodeRef ref;
  final int updatedAtMs;
  final bool manual;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sourceId': sourceId,
    'sourceBaseUrl': sourceBaseUrl,
    'videoIdentity': videoIdentity,
    'ref': ref.toJson(),
    'updatedAtMs': updatedAtMs,
    'manual': manual,
  };

  static DanmakuBinding? fromJson(Map<String, dynamic> json) {
    final sourceId = json['sourceId'];
    final sourceBaseUrl = json['sourceBaseUrl'];
    final videoIdentity = json['videoIdentity'];
    final rawRef = json['ref'];
    if (sourceId is! String ||
        sourceBaseUrl is! String ||
        videoIdentity is! String ||
        rawRef is! Map) {
      return null;
    }
    final ref = DanmakuEpisodeRef.fromJson(Map<String, dynamic>.from(rawRef));
    if (ref.episodeId.isEmpty) return null;
    return DanmakuBinding(
      sourceId: sourceId,
      sourceBaseUrl: sourceBaseUrl,
      videoIdentity: videoIdentity,
      ref: ref,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      manual: json['manual'] as bool? ?? true,
    );
  }
}

/// Serialized SharedPreferences store for explicit and discovered bindings.
/// A batch is committed with one setString call so playback never observes a
/// half-written season.
class DanmakuBindingStore {
  DanmakuBindingStore._();

  static const _prefsKey = 'dreamplayer.danmakuBindings.v1';
  static const _schemaVersion = 1;
  static Future<void> _writeTail = Future<void>.value();

  /// Widget tests use a fresh FakeAsync zone for each test. Do not retain a
  /// completed write future scheduled in a previous test's discarded zone.
  @visibleForTesting
  static void resetWriteQueueForTesting() {
    _writeTail = Future<void>.value();
  }

  static Future<DanmakuBinding?> load({
    required String sourceId,
    required String sourceBaseUrl,
    required String videoIdentity,
  }) async {
    await _writeTail;
    final root = await _readRoot();
    final raw = _sourceBucket(root, sourceId, sourceBaseUrl)[videoIdentity];
    if (raw is! Map) return null;
    return DanmakuBinding.fromJson(Map<String, dynamic>.from(raw));
  }

  static Future<Map<String, DanmakuBinding>> loadForScope(
    SeriesScope scope, {
    Iterable<String>? videoIdentities,
  }) async {
    await _writeTail;
    final root = await _readRoot();
    final bucket = _sourceBucket(root, scope.sourceId, scope.sourceBaseUrl);
    final filter = videoIdentities?.toSet();
    final result = <String, DanmakuBinding>{};
    for (final entry in bucket.entries) {
      if (filter != null && !filter.contains(entry.key)) continue;
      if (entry.value is! Map) continue;
      final binding = DanmakuBinding.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      if (binding != null) result[entry.key] = binding;
    }
    return result;
  }

  static Future<void> save(
    SeriesScope scope,
    String videoIdentity,
    DanmakuEpisodeRef ref, {
    bool manual = true,
  }) => saveAll(scope, {videoIdentity: ref}, manual: manual);

  static Future<void> remove({
    required String sourceId,
    required String sourceBaseUrl,
    required String videoIdentity,
  }) {
    return _enqueueWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      final root = await _readRoot(prefs: prefs);
      final sources = _sources(root);
      final sourceKey = _sourceKey(sourceId, sourceBaseUrl);
      final rawBucket = sources[sourceKey];
      if (rawBucket is! Map) return;
      final bucket = Map<String, dynamic>.from(rawBucket);
      if (bucket.remove(videoIdentity) == null) return;
      sources[sourceKey] = bucket;
      root['sources'] = sources;
      await prefs.setString(_prefsKey, jsonEncode(root));
    });
  }

  /// Saves [bindings] atomically. Keys in [replaceVideoIdentities] that have
  /// no new binding are removed, which lets a batch replace its entire scope
  /// without leaving stale episode choices behind.
  static Future<void> saveAll(
    SeriesScope scope,
    Map<String, DanmakuEpisodeRef> bindings, {
    Iterable<String> replaceVideoIdentities = const <String>[],
    bool manual = true,
  }) {
    return _enqueueWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      final root = await _readRoot(prefs: prefs);
      final sources = _sources(root);
      final sourceKey = _sourceKey(scope.sourceId, scope.sourceBaseUrl);
      final bucket = sources[sourceKey] is Map
          ? Map<String, dynamic>.from(sources[sourceKey] as Map)
          : <String, dynamic>{};
      for (final key in replaceVideoIdentities) {
        bucket.remove(key);
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entry in bindings.entries) {
        bucket[entry.key] = DanmakuBinding(
          sourceId: scope.sourceId,
          sourceBaseUrl: _normalizeBaseUrl(scope.sourceBaseUrl),
          videoIdentity: entry.key,
          ref: entry.value,
          updatedAtMs: now,
          manual: manual,
        ).toJson();
      }
      sources[sourceKey] = bucket;
      root['sources'] = sources;
      await prefs.setString(_prefsKey, jsonEncode(root));
    });
  }

  static Future<void> clearAll() => _enqueueWrite(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  });

  static Future<void> _enqueueWrite(Future<void> Function() action) {
    final operation = _writeTail.then((_) => action());
    _writeTail = operation.catchError((_) {});
    return operation;
  }

  static Future<Map<String, dynamic>> _readRoot({
    SharedPreferences? prefs,
  }) async {
    final preferences = prefs ?? await SharedPreferences.getInstance();
    final raw = preferences.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      return <String, dynamic>{
        'schemaVersion': _schemaVersion,
        'sources': <String, dynamic>{},
      };
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['schemaVersion'] == _schemaVersion) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // Replace only the damaged binding blob on the next write.
    }
    return <String, dynamic>{
      'schemaVersion': _schemaVersion,
      'sources': <String, dynamic>{},
    };
  }

  static Map<String, dynamic> _sources(Map<String, dynamic> root) =>
      root['sources'] is Map
      ? Map<String, dynamic>.from(root['sources'] as Map)
      : <String, dynamic>{};

  static Map<String, dynamic> _sourceBucket(
    Map<String, dynamic> root,
    String sourceId,
    String sourceBaseUrl,
  ) {
    final raw = _sources(root)[_sourceKey(sourceId, sourceBaseUrl)];
    return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  static String _sourceKey(String sourceId, String sourceBaseUrl) =>
      jsonEncode(<String>[sourceId, _normalizeBaseUrl(sourceBaseUrl)]);

  static String _normalizeBaseUrl(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');
}

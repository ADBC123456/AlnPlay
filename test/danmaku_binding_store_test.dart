import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/danmaku/binding/danmaku_binding_store.dart';
import 'package:dream_player/danmaku/identity/video_identity.dart';
import 'package:dream_player/danmaku/scraper/scrape_state.dart';

const _scope = SeriesScope(
  sourceId: 'api-a',
  sourceBaseUrl: 'https://danmaku.example/api/',
  seriesTitle: 'Show',
  seriesKey: 'tmdb:tv:1',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('batch save round-trips all bindings and replaces stale rows', () async {
    await DanmakuBindingStore.saveAll(
      _scope,
      const {
        'video-1': DanmakuEpisodeRef(
          animeId: 'anime-a',
          episodeId: 'episode-1',
          episodeTitle: '第1集',
        ),
        'video-2': DanmakuEpisodeRef(
          animeId: 'anime-a',
          episodeId: 'episode-2',
          episodeTitle: '第2集',
        ),
      },
      replaceVideoIdentities: const ['video-1', 'video-2'],
    );

    var loaded = await DanmakuBindingStore.loadForScope(_scope);
    expect(loaded.keys, containsAll(<String>['video-1', 'video-2']));
    expect(loaded['video-2']!.ref.episodeId, 'episode-2');
    expect(loaded['video-1']!.manual, isTrue);

    await DanmakuBindingStore.saveAll(
      _scope,
      const {
        'video-1': DanmakuEpisodeRef(
          animeId: 'anime-b',
          episodeId: 'replacement-1',
        ),
      },
      replaceVideoIdentities: const ['video-1', 'video-2'],
    );
    loaded = await DanmakuBindingStore.loadForScope(_scope);
    expect(loaded.keys, ['video-1']);
    expect(loaded['video-1']!.ref.episodeId, 'replacement-1');
  });

  test('bindings are isolated by source deployment', () async {
    await DanmakuBindingStore.save(
      _scope,
      'video-1',
      const DanmakuEpisodeRef(animeId: 'a', episodeId: 'a-1'),
    );
    const other = SeriesScope(
      sourceId: 'api-a',
      sourceBaseUrl: 'https://other.example/api',
      seriesTitle: 'Show',
      seriesKey: 'tmdb:tv:1',
    );

    expect(await DanmakuBindingStore.loadForScope(other), isEmpty);
    expect(
      (await DanmakuBindingStore.loadForScope(
        _scope,
      ))['video-1']!.ref.episodeId,
      'a-1',
    );
  });

  test('concurrent writes merge instead of overwriting each other', () async {
    await Future.wait([
      DanmakuBindingStore.save(
        _scope,
        'video-1',
        const DanmakuEpisodeRef(animeId: 'a', episodeId: '1'),
      ),
      DanmakuBindingStore.save(
        _scope,
        'video-2',
        const DanmakuEpisodeRef(animeId: 'a', episodeId: '2'),
      ),
    ]);

    final loaded = await DanmakuBindingStore.loadForScope(_scope);
    expect(loaded.keys, containsAll(<String>['video-1', 'video-2']));
  });

  test('remove deletes only the requested binding', () async {
    await DanmakuBindingStore.saveAll(_scope, const {
      'video-1': DanmakuEpisodeRef(animeId: 'a', episodeId: '1'),
      'video-2': DanmakuEpisodeRef(animeId: 'a', episodeId: '2'),
    });

    await DanmakuBindingStore.remove(
      sourceId: _scope.sourceId,
      sourceBaseUrl: _scope.sourceBaseUrl,
      videoIdentity: 'video-1',
    );

    final loaded = await DanmakuBindingStore.loadForScope(_scope);
    expect(loaded.keys, ['video-2']);
  });

  test('legacy raw keys remain readable and migrate on write', () async {
    final legacy = DanmakuBinding(
      sourceId: _scope.sourceId,
      sourceBaseUrl: _scope.sourceBaseUrl,
      videoIdentity: 'video-1',
      ref: const DanmakuEpisodeRef(animeId: 'a', episodeId: 'legacy'),
      updatedAtMs: 1,
      manual: true,
    );
    final sourceKey = jsonEncode(<String>[
      _scope.sourceId,
      'https://danmaku.example/api',
    ]);
    SharedPreferences.setMockInitialValues({
      'dreamplayer.danmakuBindings.v1': jsonEncode({
        'schemaVersion': 1,
        'sources': {
          sourceKey: {'video-1': legacy.toJson()},
        },
      }),
    });

    final loaded = await DanmakuBindingStore.load(
      sourceId: _scope.sourceId,
      sourceBaseUrl: _scope.sourceBaseUrl,
      videoIdentity: normalizeDanmakuIdentityKey('video-1'),
    );
    expect(loaded?.ref.episodeId, 'legacy');

    await DanmakuBindingStore.save(
      _scope,
      'video-1',
      const DanmakuEpisodeRef(animeId: 'a', episodeId: 'current'),
    );
    final all = await DanmakuBindingStore.loadForScope(_scope);
    expect(all.keys, ['video-1']);
    expect(all.values.single.ref.episodeId, 'current');
  });
}

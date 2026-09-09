import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/danmaku/binding/danmaku_binding_store.dart';
import 'package:dream_player/danmaku/identity/video_identity.dart' as vid;
import 'package:dream_player/danmaku/models/danmaku_models.dart';
import 'package:dream_player/danmaku/scraper/scrape_state.dart';
import 'package:dream_player/danmaku/service/danmaku_service.dart';
import 'package:dream_player/danmaku/source/danmaku_source_store.dart';
import 'package:dream_player/danmaku/source/danmaku_source_registry.dart';
import 'package:dream_player/models/video_item.dart';

Future<void> body() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final hits = <String>[];
  server.listen((req) async {
    hits.add(req.uri.path);
    if (req.uri.path == '/api/v2/match') {
      await utf8.decoder.bind(req).join();
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'success': true,
          'isMatched': true,
          'matches': [
            {
              'episodeId': 10001,
              'animeId': 100,
              'animeTitle': 'Show S2',
              'episodeTitle': '第3集',
              'shift': 0,
              'url': '',
            },
          ],
        }),
      );
      await req.response.close();
    } else if (req.uri.path == '/api/v2/comment/10001') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'success': true,
          'errorCode': 0,
          'errorMessage': '',
          'count': 2,
          'videoDuration': 1400.5,
          'comments': [
            {
              'p': '12.50,1,16777215,[bilibili]',
              'm': 'hello',
              'cid': 1,
              'like': 3,
            },
            {'p': '30,5,255,[acfun]', 'm': 'top comment', 'cid': 2},
          ],
        }),
      );
      await req.response.close();
    } else {
      req.response.statusCode = 404;
      await req.response.close();
    }
  });

  final tmp = await Directory.systemTemp.createTemp('danmaku_smoke');
  final service = DanmakuService.forTesting(
    cacheDirectory: tmp,
    configs: [
      DanmakuSourceConfig(
        id: 'smoke_src',
        name: 'smoke',
        baseUrl: 'http://127.0.0.1:${server.port}',
      ),
    ],
  );
  await service.init();
  expect(service.primarySource, isNotNull);

  final identity = vid.VideoIdentity(
    stableKey: 'danmaku:smoke/file.mkv',
    fileName: 'Show.S02E03.mkv',
    fileSize: 123456789,
  );

  final first = await service.ensureForVideo(identity);
  expect(first.status, DanmakuStatus.ready);
  expect(first.items, hasLength(2));
  expect(first.items[1].type, DanmakuType.top);

  // Second call is a cache hit: no additional network requests.
  final before = hits.length;
  final second = await service.ensureForVideo(identity);
  expect(second.status, DanmakuStatus.ready);
  expect(hits.length, before);

  // Cache entry persisted with a string episodeId.
  final files = tmp.listSync(recursive: true).whereType<File>().toList();
  expect(files, isNotEmpty);
  final cached =
      jsonDecode(files.first.readAsStringSync()) as Map<String, dynamic>;
  expect(cached['episodeId'], '10001');

  await tmp.delete(recursive: true);
  await server.close(force: true);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('DanmakuService: match -> load -> cache hit end to end', () async {
    await body();
  });

  test(
    'force refresh does not route old request progress to new listeners',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstCommentArrived = Completer<void>();
      final releaseFirstComment = Completer<void>();
      var commentRequests = 0;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/match')) {
          await utf8.decoder.bind(request).join();
          request.response.write(
            jsonEncode({
              'success': true,
              'isMatched': true,
              'matches': [
                {
                  'episodeId': 'episode',
                  'animeId': 'anime',
                  'animeTitle': 'Show',
                  'episodeTitle': 'Episode 1',
                },
              ],
            }),
          );
        } else if (request.uri.path.contains('/comment/')) {
          commentRequests++;
          if (commentRequests == 1) {
            firstCommentArrived.complete();
            await releaseFirstComment.future;
          }
          request.response.write(jsonEncode({'comments': <Object>[]}));
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final tmp = await Directory.systemTemp.createTemp(
        'danmaku_force_progress',
      );
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final service = DanmakuService.forTesting(
        cacheDirectory: tmp,
        configs: [
          DanmakuSourceConfig(
            id: 'force_src',
            name: 'force',
            baseUrl: 'http://127.0.0.1:${server.port}',
          ),
        ],
      );
      final identity = vid.VideoIdentity(
        stableKey: 'force-progress',
        fileName: 'Show.S01E01.mkv',
      );
      final oldProgress = <DanmakuLoadProgress>[];
      final newProgress = <DanmakuLoadProgress>[];
      final first = service.ensureForVideo(
        identity,
        onProgress: oldProgress.add,
      );
      await firstCommentArrived.future;
      await service.ensureForVideo(
        identity,
        forceRefresh: true,
        onProgress: newProgress.add,
      );
      final newCount = newProgress.length;
      releaseFirstComment.complete();
      await first;

      expect(oldProgress, isNotEmpty);
      expect(newProgress.length, newCount);
    },
  );

  test(
    'falls back to scraped title and exact episode after filename no-match',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final hits = <String>[];
      server.listen((request) async {
        hits.add(request.uri.path);
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/match')) {
          await utf8.decoder.bind(request).join();
          request.response.write(
            jsonEncode({'success': true, 'isMatched': false, 'matches': []}),
          );
        } else if (request.uri.path.endsWith('/search/episodes')) {
          request.response.write(
            jsonEncode({
              'success': true,
              'animes': [
                {
                  'animeId': 'anime-1',
                  'animeTitle': '正式剧名',
                  'episodes': [
                    {
                      'episodeId': 'episode-12',
                      'episodeTitle': '第12集',
                      'url': '',
                    },
                  ],
                },
              ],
            }),
          );
        } else if (request.uri.path.endsWith('/comment/episode-12')) {
          request.response.write(
            jsonEncode({
              'success': true,
              'videoDuration': 1200,
              'comments': [
                {'p': '1,1,16777215,[test]', 'm': 'matched by metadata'},
              ],
            }),
          );
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final tmp = await Directory.systemTemp.createTemp('danmaku_metadata');
      final service = DanmakuService.forTesting(
        cacheDirectory: tmp,
        configs: [
          DanmakuSourceConfig(
            id: 'metadata_src',
            name: 'metadata',
            baseUrl: 'http://127.0.0.1:${server.port}',
          ),
        ],
      );
      const identity = vid.VideoIdentity(
        stableKey: 'danmaku:opaque-file',
        fileName: 'unrelated-name.mkv',
      );

      final outcome = await service.ensureForVideo(
        identity,
        metadata: const VideoMetadataContext(
          titleId: 'tmdb:tv:1',
          displayTitle: '正式剧名',
          seasonNumber: 1,
          episodeNumber: 12,
          episodeTitle: '正式集名',
          revision: 3,
        ),
      );

      expect(outcome.status, DanmakuStatus.ready);
      expect(outcome.items.single.text, 'matched by metadata');
      expect(hits, contains('/api/v2/search/episodes'));
      expect(hits, contains('/api/v2/comment/episode-12'));
      await tmp.delete(recursive: true);
      await server.close(force: true);
    },
  );

  test(
    'saved binding bypasses automatic match and loads exact episode',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final hits = <String>[];
      server.listen((request) async {
        hits.add(request.uri.path);
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/comment/manual-12')) {
          request.response.write(
            jsonEncode({
              'success': true,
              'videoDuration': 1200,
              'comments': [
                {'p': '1,1,16777215,[test]', 'm': 'manual binding'},
              ],
            }),
          );
        } else {
          request.response.statusCode = 500;
        }
        await request.response.close();
      });
      final tmp = await Directory.systemTemp.createTemp('danmaku_binding');
      final config = DanmakuSourceConfig(
        id: 'bound_src',
        name: 'bound',
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      final service = DanmakuService.forTesting(
        cacheDirectory: tmp,
        configs: [config],
      );
      const identity = vid.VideoIdentity(
        stableKey: 'danmaku:bound-file',
        fileName: 'ambiguous.mkv',
      );
      final scope = SeriesScope(
        sourceId: config.id,
        sourceBaseUrl: config.baseUrl,
        seriesTitle: 'Show',
        seriesKey: 'tmdb:tv:1',
      );
      await DanmakuBindingStore.save(
        scope,
        identity.stableKey,
        const DanmakuEpisodeRef(
          animeId: 'manual-anime',
          episodeId: 'manual-12',
          episodeTitle: '第12集',
        ),
      );

      final outcome = await service.ensureForVideo(identity);

      expect(outcome.status, DanmakuStatus.ready);
      expect(outcome.items.single.text, 'manual binding');
      expect(hits, ['/api/v2/comment/manual-12']);
      await tmp.delete(recursive: true);
      await server.close(force: true);
    },
  );
}

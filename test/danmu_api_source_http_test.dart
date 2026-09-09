import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/danmaku/source/danmaku_source_registry.dart';
import 'package:dream_player/danmaku/source/danmu_api_source.dart';

void main() {
  Future<HttpServer> startServer(
    FutureOr<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handler);
    return server;
  }

  String baseUrl(HttpServer server, [String path = '']) =>
      'http://${server.address.address}:${server.port}$path';

  Future<void> jsonResponse(
    HttpRequest request,
    Map<String, Object?> body, {
    int status = HttpStatus.ok,
  }) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  test('preserves a base path and appends the configured token', () async {
    Uri? received;
    final server = await startServer((request) async {
      received = request.uri;
      await jsonResponse(request, {'success': true, 'animes': <Object>[]});
    });
    addTearDown(() => server.close(force: true));

    final source = DanmuApiSource(
      DanmuApiConfig(baseUrl: baseUrl(server, '/gateway'), token: '87654321'),
    );
    await source.searchEpisodes(anime: 'Example Show');

    expect(received?.path, '/gateway/87654321/api/v2/search/episodes');
    expect(received?.queryParameters['anime'], 'Example Show');
  });

  test('does not duplicate token or api/v2 in a copied endpoint URL', () async {
    Uri? received;
    final server = await startServer((request) async {
      received = request.uri;
      await jsonResponse(request, {'success': true, 'animes': <Object>[]});
    });
    addTearDown(() => server.close(force: true));

    final source = DanmuApiSource(
      DanmuApiConfig(
        baseUrl: baseUrl(server, '/87654321/api/v2/'),
        token: '87654321',
      ),
    );
    await source.searchEpisodes(anime: 'Example');

    expect(received?.path, '/87654321/api/v2/search/episodes');
  });

  test('inserts a separate token into a base ending in api/v2', () async {
    Uri? received;
    final server = await startServer((request) async {
      received = request.uri;
      await jsonResponse(request, {'success': true, 'animes': <Object>[]});
    });
    addTearDown(() => server.close(force: true));

    final source = DanmuApiSource(
      DanmuApiConfig(
        baseUrl: baseUrl(server, '/api/v2'),
        token: 'custom-token',
      ),
    );
    await source.searchEpisodes(anime: 'Example');

    expect(received?.path, '/custom-token/api/v2/search/episodes');
  });

  test('sends the documented match body and parses comment JSON', () async {
    Map<String, dynamic>? matchBody;
    final server = await startServer((request) async {
      if (request.uri.path.endsWith('/match')) {
        matchBody =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        await jsonResponse(request, {
          'success': true,
          'isMatched': true,
          'matches': [
            {
              'episodeId': 10001,
              'animeId': '200',
              'animeTitle': 'Example',
              'episodeTitle': 'Episode 1',
              'shift': '2',
            },
          ],
        });
        return;
      }
      await jsonResponse(request, {
        'success': true,
        'videoDuration': '1440.5',
        'comments': [
          {
            'p': '12.5,5,16711680,[bilibili]',
            'm': 'hello',
            'cid': 9001,
            'like': '8',
          },
        ],
      });
    });
    addTearDown(() => server.close(force: true));

    final source = DanmuApiSource(DanmuApiConfig(baseUrl: baseUrl(server)));
    final match = await source.match(
      fileName: 'Example.S01E01.mkv',
      fileHash: 'abc123',
      fileSize: 1024,
    );
    final comments = await source.fetchComments(episodeId: match!.episodeId);

    expect(matchBody, {
      'fileName': 'Example.S01E01.mkv',
      'fileHash': 'abc123',
      'fileSize': 1024,
      'matchMode': 'hashAndFileName',
    });
    expect(match.episodeId, '10001');
    expect(match.shift, 2);
    expect(comments.videoDurationSeconds, 1440.5);
    expect(comments.comments.single.mode, 5);
    expect(comments.comments.single.colorRgb, 0xFF0000);
    expect(comments.comments.single.likes, 8);
  });

  test('accepts a real deployment bare comment payload', () async {
    final server = await startServer((request) async {
      await jsonResponse(request, {
        'videoDuration': 1415.56,
        'count': 1,
        'comments': [
          {'cid': 1, 'p': '3.5,1,16777215,[bilibili]', 'm': '正常弹幕'},
        ],
      });
    });
    addTearDown(() => server.close(force: true));

    final source = DanmuApiSource(DanmuApiConfig(baseUrl: baseUrl(server)));
    final result = await source.fetchComments(episodeId: '14431');

    expect(result.videoDurationSeconds, 1415.56);
    expect(result.comments.single.content, '正常弹幕');
  });

  test(
    'reports downloaded bytes, speed, and parsing with known length',
    () async {
      final body = utf8.encode(
        jsonEncode({
          'videoDuration': 10,
          'comments': [
            {'p': '1,1,16777215,source', 'm': 'hello'},
          ],
        }),
      );
      final server = await startServer((request) async {
        request.response
          ..headers.contentType = ContentType.json
          ..contentLength = body.length
          ..add(body);
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final source = DanmuApiSource(DanmuApiConfig(baseUrl: baseUrl(server)));
      final progress = <DanmakuLoadProgress>[];

      await source.fetchCommentsWithProgress(
        episodeId: 'episode',
        onProgress: progress.add,
      );

      final downloads = progress
          .where((item) => item.phase == DanmakuLoadPhase.downloading)
          .toList();
      expect(downloads.last.bytesReceived, body.length);
      expect(downloads.last.totalBytes, body.length);
      expect(downloads.last.fraction, 1);
      expect(downloads.last.bytesPerSecond, greaterThan(0));
      expect(progress.last.phase, DanmakuLoadPhase.parsing);
    },
  );

  test('unknown content length never reports a percentage', () async {
    final server = await startServer((request) async {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'comments': <Object>[]}));
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final source = DanmuApiSource(DanmuApiConfig(baseUrl: baseUrl(server)));
    final progress = <DanmakuLoadProgress>[];

    await source.fetchCommentsWithProgress(
      episodeId: 'episode',
      onProgress: progress.add,
    );

    final downloads = progress.where(
      (item) => item.phase == DanmakuLoadPhase.downloading,
    );
    expect(downloads, isNotEmpty);
    expect(downloads.every((item) => item.fraction == null), isTrue);
  });

  test(
    'auto-decompressed responses do not use compressed length as total',
    () async {
      final plain = utf8.encode(jsonEncode({'comments': <Object>[]}));
      final compressed = gzip.encode(plain);
      final server = await startServer((request) async {
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set(HttpHeaders.contentEncodingHeader, 'gzip')
          ..contentLength = compressed.length
          ..add(compressed);
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      final source = DanmuApiSource(DanmuApiConfig(baseUrl: baseUrl(server)));
      final progress = <DanmakuLoadProgress>[];

      await source.fetchCommentsWithProgress(
        episodeId: 'episode',
        onProgress: progress.add,
      );

      final downloads = progress.where(
        (item) => item.phase == DanmakuLoadPhase.downloading,
      );
      expect(downloads, isNotEmpty);
      expect(downloads.every((item) => item.totalBytes == null), isTrue);
      expect(downloads.every((item) => item.fraction == null), isTrue);
    },
  );

  test('rejects a comment payload without a comments list', () async {
    final server = await startServer((request) async {
      await jsonResponse(request, {'count': 10});
    });
    addTearDown(() => server.close(force: true));

    final source = DanmuApiSource(DanmuApiConfig(baseUrl: baseUrl(server)));
    await expectLater(
      source.fetchComments(episodeId: 'broken'),
      throwsA(isA<DanmakuProtocolException>()),
    );
  });

  test('retries a server failure and then succeeds', () async {
    var requests = 0;
    final server = await startServer((request) async {
      requests++;
      if (requests == 1) {
        await jsonResponse(request, {
          'success': false,
        }, status: HttpStatus.internalServerError);
      } else {
        await jsonResponse(request, {'success': true, 'animes': <Object>[]});
      }
    });
    addTearDown(() => server.close(force: true));

    final source = DanmuApiSource(
      DanmuApiConfig(baseUrl: baseUrl(server)),
      retryPolicy: const DanmuApiRetryPolicy(
        maxAttempts: 2,
        initialBackoff: Duration.zero,
        maxBackoff: Duration.zero,
      ),
    );
    await source.searchEpisodes(anime: 'Example');
    expect(requests, 2);
  });

  test('does not retry authentication failures', () async {
    var requests = 0;
    final server = await startServer((request) async {
      requests++;
      await jsonResponse(request, {
        'success': false,
      }, status: HttpStatus.unauthorized);
    });
    addTearDown(() => server.close(force: true));

    final source = DanmuApiSource(
      DanmuApiConfig(baseUrl: baseUrl(server)),
      retryPolicy: const DanmuApiRetryPolicy(
        maxAttempts: 3,
        initialBackoff: Duration.zero,
      ),
    );
    await expectLater(
      source.searchEpisodes(anime: 'Example'),
      throwsA(isA<DanmakuAuthException>()),
    );
    expect(requests, 1);
  });

  test('does not silently select the first ambiguous match', () async {
    final server = await startServer((request) async {
      await jsonResponse(request, {
        'success': true,
        'isMatched': true,
        'matches': [
          {'animeId': 1, 'episodeId': 101},
          {'animeId': 2, 'episodeId': 201},
        ],
      });
    });
    addTearDown(() => server.close(force: true));
    final source = DanmuApiSource(DanmuApiConfig(baseUrl: baseUrl(server)));

    expect(await source.match(fileName: 'Ambiguous.S01E01.mkv'), isNull);
  });

  test(
    'automatic match ignores preview entries returned before full episode',
    () async {
      final server = await startServer((request) async {
        await jsonResponse(request, {
          'success': true,
          'isMatched': true,
          'matches': [
            {
              'animeId': 1,
              'episodeId': 101,
              'episodeTitle': '【bilibili1】 星海飞驰第1集预告',
            },
            {'animeId': 1, 'episodeId': 102, 'episodeTitle': '第1集 风起天南'},
          ],
        });
      });
      addTearDown(() => server.close(force: true));
      final source = DanmuApiSource(DanmuApiConfig(baseUrl: baseUrl(server)));

      final match = await source.match(fileName: '凡人修仙传.S01E01.mkv');
      expect(match?.episodeId, '102');
    },
  );

  test(
    'automatic match returns no match when only previews are returned',
    () async {
      final server = await startServer((request) async {
        await jsonResponse(request, {
          'success': true,
          'isMatched': true,
          'matches': [
            {'animeId': 1, 'episodeId': 101, 'episodeTitle': '星海飞驰第1集预告'},
          ],
        });
      });
      addTearDown(() => server.close(force: true));
      final source = DanmuApiSource(DanmuApiConfig(baseUrl: baseUrl(server)));

      expect(await source.match(fileName: '凡人修仙传.S01E01.mkv'), isNull);
    },
  );

  test('cancels an in-flight response body immediately', () async {
    final requestSeen = Completer<void>();
    final server = await startServer((request) {
      if (!requestSeen.isCompleted) requestSeen.complete();
      // Deliberately leave the response open until cancellation aborts it.
    });
    addTearDown(() => server.close(force: true));
    final token = DanmakuCancelToken();
    final source = DanmuApiSource(
      DanmuApiConfig(baseUrl: baseUrl(server)),
      retryPolicy: const DanmuApiRetryPolicy(maxAttempts: 1),
    );

    final future = source.searchEpisodes(anime: 'Example', cancelToken: token);
    await requestSeen.future.timeout(const Duration(seconds: 2));
    token.cancel();

    await expectLater(
      future.timeout(const Duration(seconds: 2)),
      throwsA(isA<DanmakuCancelledException>()),
    );
  });

  test('exhausted socket retries preserve the typed network error', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = baseUrl(server);
    await server.close(force: true);
    final source = DanmuApiSource(
      DanmuApiConfig(baseUrl: url),
      retryPolicy: const DanmuApiRetryPolicy(maxAttempts: 1),
    );

    await expectLater(
      source.searchEpisodes(anime: 'Example'),
      throwsA(isA<DanmakuNetworkException>()),
    );
  });
}

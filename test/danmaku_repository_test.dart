import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:dream_player/danmaku/repository/danmaku_cache.dart';
import 'package:dream_player/danmaku/repository/danmaku_repository.dart';
import 'package:dream_player/danmaku/source/danmaku_source_registry.dart';

void main() {
  late Directory temp;
  late DanmakuSourceRegistry registry;
  late DanmakuRepository repository;
  late _Source source;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dreamplayer_danmaku_repo_');
    registry = DanmakuSourceRegistry();
    source = _Source();
    registry.register(source);
    repository = DanmakuRepository(
      cache: DanmakuCache(directory: temp),
      registry: registry,
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'uses the injected registry and applies match shift before caching',
    () async {
      final result = await repository.loadForVideo(
        sourceId: source.sourceId,
        baseUrl: 'https://danmaku.example',
        request: const DanmakuVideoRequest(
          videoIdentity: 'video-1',
          fileName: 'Example.S01E01.mkv',
        ),
      );

      expect(result.status, DanmakuFetchStatus.fromNetwork);
      expect(result.entry!.comments, hasLength(1));
      expect(result.entry!.comments.single.timeSeconds, 1);
      expect(result.entry!.fileName, 'Example.S01E01.mkv');
      expect(result.entry!.appliedShiftSeconds, -2);

      final cached = await repository.loadForVideo(
        sourceId: source.sourceId,
        baseUrl: 'https://danmaku.example',
        request: const DanmakuVideoRequest(
          videoIdentity: 'video-1',
          fileName: 'Example.S01E01.mkv',
        ),
      );
      expect(cached.status, DanmakuFetchStatus.fromCache);
      expect(source.fetchCalls, 1);
    },
  );

  test('applies a known episode shift in the batch scrape path', () async {
    final result = await repository.loadForEpisode(
      sourceId: source.sourceId,
      baseUrl: 'https://danmaku.example',
      request: const DanmakuVideoRequest(
        videoIdentity: 'video-2',
        fileName: 'Example.S01E02.mkv',
      ),
      episodeId: 'episode-2',
      shiftSeconds: 2.5,
    );

    expect(result.entry!.comments.map((comment) => comment.timeSeconds), [
      3.5,
      5.5,
    ]);
    expect(result.entry!.appliedShiftSeconds, 2.5);
  });

  test(
    'reports real fallback source phases without invented byte totals',
    () async {
      final progress = <DanmakuLoadProgress>[];
      await repository.loadForVideo(
        sourceId: source.sourceId,
        baseUrl: 'https://danmaku.example',
        request: const DanmakuVideoRequest(
          videoIdentity: 'video-progress',
          fileName: 'Example.S01E01.mkv',
        ),
        onProgress: progress.add,
      );

      expect(progress.map((item) => item.phase), [
        DanmakuLoadPhase.matching,
        DanmakuLoadPhase.downloading,
        DanmakuLoadPhase.parsing,
      ]);
      expect(progress[1].bytesReceived, isNull);
      expect(progress[1].totalBytes, isNull);
      expect(progress[1].fraction, isNull);
    },
  );

  test('a changed binding does not reuse another episode cache', () async {
    const request = DanmakuVideoRequest(
      videoIdentity: 'video-rebound',
      fileName: 'Example.S01E02.mkv',
    );
    await repository.loadForEpisode(
      sourceId: source.sourceId,
      baseUrl: 'https://danmaku.example',
      request: request,
      episodeId: 'old-episode',
    );

    final rebound = await repository.loadForEpisode(
      sourceId: source.sourceId,
      baseUrl: 'https://danmaku.example',
      request: request,
      episodeId: 'new-episode',
    );

    expect(rebound.status, DanmakuFetchStatus.fromNetwork);
    expect(rebound.entry!.episodeId, 'new-episode');
    expect(source.requestedEpisodeIds, ['old-episode', 'new-episode']);
  });

  test('clearAll removes disk and memory entries', () async {
    await repository.loadForVideo(
      sourceId: source.sourceId,
      baseUrl: 'https://danmaku.example',
      request: const DanmakuVideoRequest(
        videoIdentity: 'video-clear',
        fileName: 'Example.S01E03.mkv',
      ),
    );

    await repository.cache.clearAll();

    expect(
      await repository.cache.read(
        sourceId: source.sourceId,
        baseUrl: 'https://danmaku.example',
        videoIdentity: 'video-clear',
      ),
      isNull,
    );
  });

  test('empty cache expires after five minutes', () async {
    var now = DateTime(2026, 9, 20, 12);
    source.returnEmpty = true;
    repository = DanmakuRepository(
      cache: DanmakuCache(directory: temp),
      registry: registry,
      clock: () => now,
    );
    const request = DanmakuVideoRequest(
      videoIdentity: 'empty-video',
      fileName: 'Example.S01E01.mkv',
    );

    expect(
      (await repository.loadForVideo(
        sourceId: source.sourceId,
        baseUrl: 'https://danmaku.example',
        request: request,
      )).status,
      DanmakuFetchStatus.empty,
    );
    now = now.add(const Duration(minutes: 4));
    await repository.loadForVideo(
      sourceId: source.sourceId,
      baseUrl: 'https://danmaku.example',
      request: request,
    );
    expect(source.fetchCalls, 1);

    now = now.add(const Duration(minutes: 2));
    await repository.loadForVideo(
      sourceId: source.sourceId,
      baseUrl: 'https://danmaku.example',
      request: request,
    );
    expect(source.fetchCalls, 2);
  });

  test('an older request cannot overwrite a newer forced refresh', () async {
    final delayed = _DelayedSource();
    registry = DanmakuSourceRegistry()..register(delayed);
    repository = DanmakuRepository(
      cache: DanmakuCache(directory: temp),
      registry: registry,
    );
    const request = DanmakuVideoRequest(
      videoIdentity: 'race-video',
      fileName: 'Example.S01E01.mkv',
    );
    final first = repository.loadForEpisode(
      sourceId: delayed.sourceId,
      baseUrl: 'https://danmaku.example',
      request: request,
      episodeId: 'episode-1',
      forceRefresh: true,
    );
    await delayed.waitForRequests(1);
    final second = repository.loadForEpisode(
      sourceId: delayed.sourceId,
      baseUrl: 'https://danmaku.example',
      request: request,
      episodeId: 'episode-1',
      forceRefresh: true,
    );
    await delayed.waitForRequests(2);
    delayed.requests[1].complete(_comments('new'));
    await second;
    delayed.requests[0].complete(_comments('old'));
    await first;

    final cached = await repository.cache.read(
      sourceId: delayed.sourceId,
      baseUrl: 'https://danmaku.example',
      videoIdentity: request.videoIdentity,
    );
    expect(cached!.comments.single.content, 'new');
  });
}

DanmakuSourceComments _comments(String value) => DanmakuSourceComments(
  comments: [
    DanmakuSourceComment(
      timeSeconds: 1,
      mode: 1,
      colorRgb: 0xFFFFFF,
      content: value,
    ),
  ],
);

class _Source implements DanmakuSource {
  int fetchCalls = 0;
  bool returnEmpty = false;
  final List<String> requestedEpisodeIds = [];

  @override
  String get sourceId => 'test-source';

  @override
  String get displayName => 'Test source';

  @override
  String get cacheScope => 'test-scope';

  @override
  Future<void> verifyConnectivity({DanmakuCancelToken? cancelToken}) async {}

  @override
  Future<DanmakuSourceMatch?> match({
    required String fileName,
    String? fileHash,
    int? fileSize,
    String? matchMode,
    DanmakuCancelToken? cancelToken,
  }) async => const DanmakuSourceMatch(
    episodeId: 'episode-1',
    animeId: 'anime-1',
    animeTitle: 'Example',
    episodeTitle: 'Episode 1',
    shift: -2,
  );

  @override
  Future<DanmakuSourceComments> fetchComments({
    required String episodeId,
    DanmakuCancelToken? cancelToken,
  }) async {
    fetchCalls++;
    requestedEpisodeIds.add(episodeId);
    if (returnEmpty) return const DanmakuSourceComments(comments: []);
    return const DanmakuSourceComments(
      comments: [
        DanmakuSourceComment(
          timeSeconds: 1,
          mode: 1,
          colorRgb: 0xFFFFFF,
          content: 'too early after shift',
        ),
        DanmakuSourceComment(
          timeSeconds: 3,
          mode: 5,
          colorRgb: 0xFF0000,
          content: 'kept',
        ),
      ],
    );
  }

  @override
  Future<List<DanmakuSourceEpisodeGroup>> searchEpisodes({
    required String anime,
    DanmakuCancelToken? cancelToken,
  }) async => const [];

  @override
  Future<DanmakuSourceEpisodeGroup?> bangumi({required String animeId}) async =>
      null;

  @override
  Future<List<DanmakuSourceComment>> fetchSegmentComments({
    required DanmakuSegment segment,
    DanmakuCancelToken? cancelToken,
  }) async => const [];
}

class _DelayedSource extends _Source {
  final List<Completer<DanmakuSourceComments>> requests = [];

  @override
  Future<DanmakuSourceComments> fetchComments({
    required String episodeId,
    DanmakuCancelToken? cancelToken,
  }) {
    final request = Completer<DanmakuSourceComments>();
    requests.add(request);
    return request.future;
  }

  Future<void> waitForRequests(int count) async {
    while (requests.length < count) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

import 'dart:io';

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
}

class _Source implements DanmakuSource {
  int fetchCalls = 0;
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

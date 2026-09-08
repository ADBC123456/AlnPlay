import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dream_player/danmaku/binding/danmaku_binding_store.dart';

import 'package:dream_player/danmaku/scraper/scrape_state.dart';
import 'package:dream_player/danmaku/scraper/series_scraper.dart';
import 'package:dream_player/danmaku/scraper/video_enumerator.dart';
import 'package:dream_player/danmaku/service/danmaku_service.dart';
import 'package:dream_player/danmaku/source/danmaku_source_store.dart';
import 'package:dream_player/danmaku/source/danmaku_source_registry.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/screens/danmaku_scrape_screen.dart';
import 'package:dream_player/services/library_folders.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 80; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) return;
    }
    fail(
      'Timed out waiting for $finder; visible: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(" | ")}',
    );
  }

  final folder = LibraryFolder(
    id: 'show',
    name: 'Example Show',
    path: '/shows/example',
    addedAt: DateTime(2026),
  );

  Future<_Repository> mountDirectPicker(
    WidgetTester tester, {
    required bool singleEpisode,
  }) async {
    DanmakuBindingStore.resetWriteQueueForTesting();
    SharedPreferences.setMockInitialValues({});
    final repository = _Repository();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DanmakuScrapeScreen(
          folder: folder,
          seriesTitle: folder.name,
          service: DanmakuService.forTesting(
            configs: const [
              DanmakuSourceConfig(
                id: 'test',
                name: 'Test source',
                baseUrl: 'https://example.invalid',
              ),
            ],
          ),
          enumerateFolder: false,
          openSeriesPickerOnReady: true,
          matchSingleEpisode: singleEpisode,
          suggestedEpisode: 45,
          initialVideos: [
            const ScrapeVideo(
              key: 'ep45',
              fileName: 'Show.S01E45.mkv',
              season: 1,
              episode: 45,
            ),
            if (!singleEpisode)
              const ScrapeVideo(
                key: 'ep1',
                fileName: 'Show.S01E01.mkv',
                season: 1,
                episode: 1,
              ),
          ],
          scraperFactory: (_, _, changed) => SeriesScraper(
            source: _Source(),
            repository: repository,
            minRequestGap: Duration.zero,
            backoffBase: Duration.zero,
            onChanged: changed,
          ),
        ),
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const Key('series-candidate-anime')),
    );
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets(
    'single episode opens series first then positions current episode',
    (tester) async {
      final repository = await mountDirectPicker(tester, singleEpisode: true);
      await tester.tap(find.byKey(const Key('series-candidate-anime')));
      await pumpUntilFound(
        tester,
        find.byKey(const Key('episode-candidate-episode-45')),
      );
      await tester.pumpAndSettle();
      final current = find.byKey(const Key('episode-candidate-episode-45'));
      final first = find.byKey(const Key('episode-candidate-episode-1'));
      expect(
        tester.getTopLeft(current).dy,
        lessThan(tester.getTopLeft(first).dy),
      );
      expect(
        find.byKey(const Key('episode-candidate-preview-1')),
        findsNothing,
      );
      await tester.tap(current);
      await pumpUntilFound(tester, find.text('1 / 1 · Completed'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirm-batch-match')), findsNothing);
      expect(repository.videoKeys, isEmpty);
      expect(find.text('Show.S01E01.mkv'), findsNothing);
    },
  );

  testWidgets(
    'season selection starts scraping at episode one despite resume at 45',
    (tester) async {
      final repository = await mountDirectPicker(tester, singleEpisode: false);
      await tester.tap(find.byKey(const Key('series-candidate-anime')));
      await pumpUntilFound(tester, find.text('2 / 2 · Completed'));
      await tester.pumpAndSettle();
      expect(repository.videoKeys, ['danmaku:ep1', 'danmaku:ep45']);
      expect(repository.episodeIds, ['episode-1', 'episode-45']);
      expect(find.byKey(const Key('confirm-batch-match')), findsNothing);
      expect(find.text('Select first remote episode'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('runs the series scraper and exposes progress actions', (
    tester,
  ) async {
    DanmakuBindingStore.resetWriteQueueForTesting();
    SharedPreferences.setMockInitialValues({
      kDanmakuSourcesPref: jsonEncode([
        const DanmakuSourceConfig(
          id: 'test',
          name: 'Test source',
          baseUrl: 'https://example.invalid',
        ).toJson(),
      ]),
    });
    final enumerator = DanmakuVideoEnumerator(gateway: _ListingGateway());
    final repository = _Repository();

    final service = DanmakuService.forTesting(
      configs: const [
        DanmakuSourceConfig(
          id: 'test',
          name: 'Test source',
          baseUrl: 'https://example.invalid',
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DanmakuScrapeScreen(
          folder: folder,
          seriesTitle: folder.name,
          service: service,
          enumerator: enumerator,
          scraperFactory: (_, _, changed) => SeriesScraper(
            source: _Source(),
            repository: repository,
            minRequestGap: Duration.zero,
            backoffBase: Duration.zero,
            onChanged: changed,
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('0 / 1 · Ready'));

    expect(find.text('0 / 1 · Ready'), findsOneWidget);
    expect(repository.videoKeys, isEmpty);
    expect(find.byKey(const Key('precache-season')), findsOneWidget);

    await tester.tap(find.byKey(const Key('precache-season')));
    await pumpUntilFound(tester, find.text('1 / 1 · Completed'));
    expect(find.text('success · 3'), findsOneWidget);
    expect(repository.videoKeys, [
      'danmaku:/shows/example/Example.Show.S01E01.mkv',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows an actionable empty-source state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DanmakuScrapeScreen(
          folder: folder,
          seriesTitle: folder.name,
          service: DanmakuService.forTesting(),
        ),
      ),
    );
    await pumpUntilFound(
      tester,
      find.textContaining('No danmaku source is enabled'),
    );

    expect(find.textContaining('No danmaku source is enabled'), findsOneWidget);
    expect(find.byKey(const Key('configure-source')), findsOneWidget);
  });
}

class _ListingGateway implements DanmakuListingGateway {
  @override
  Future<FolderListing> listFolder(VideoSource source, String path) async =>
      const FolderListing(
        videos: [
          VideoItem(
            id: 'ep1',
            title: 'Example.Show.S01E01.mkv',
            path: '/shows/example/Example.Show.S01E01.mkv',
            duration: Duration.zero,
          ),
        ],
      );
}

class _Source implements DanmakuScrapeSource {
  @override
  Future<List<DanmakuCatalogAnime>> searchEpisodes(
    String title, {
    DanmakuCancelToken? cancelToken,
  }) async => const [
    DanmakuCatalogAnime(
      animeId: 'anime',
      animeTitle: 'Example Show',
      episodes: [
        DanmakuCatalogEpisode(
          episodeId: 'preview-1',
          episodeTitle: '第1集预告',
          episodeNumber: 1,
        ),
        DanmakuCatalogEpisode(
          episodeId: 'episode-1',
          episodeTitle: 'Episode 1',
          episodeNumber: 1,
        ),
        DanmakuCatalogEpisode(
          episodeId: 'episode-45',
          episodeTitle: 'Episode 45',
          episodeNumber: 45,
        ),
      ],
    ),
  ];

  @override
  Future<DanmakuEpisodeRef?> match(
    VideoIdentity video, {
    DanmakuCancelToken? cancelToken,
  }) async => null;
}

class _Repository implements DanmakuScrapeRepository {
  final List<String> videoKeys = [];
  final List<String> episodeIds = [];

  @override
  Future<int> fetchAndCache(
    DanmakuEpisodeRef ref,
    String videoKey, {
    DanmakuCancelToken? cancelToken,
  }) async {
    videoKeys.add(videoKey);
    episodeIds.add(ref.episodeId);
    return 3;
  }

  @override
  Future<bool> hasValidCache(
    String videoKey, {
    bool forceRefresh = false,
    String? episodeId,
  }) async => false;
}

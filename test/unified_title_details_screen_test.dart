import 'dart:convert';

import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/repository/library_repository.dart';
import 'package:dream_player/library/unified_library_service.dart';
import 'package:dream_player/screens/unified_title_details_screen.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/continue_watching.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final size in [
    const Size(320, 700),
    const Size(600, 834),
    const Size(834, 1194),
    const Size(1194, 834),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'latest episode is centered with accessible layout at $size / $scale',
        (tester) async {
          final episodes = List.generate(
            100,
            (index) => LibraryEpisode(
              id: 's2:e${index + 1}',
              titleId: _title.id,
              seasonNumber: 2,
              episodeNumber: index + 1,
              displayName: 'Episode ${index + 1}',
            ),
          );
          final current = episodes[73];
          final entry = ContinueWatchingEntry(
            video: VideoItem(
              id: current.id,
              title: current.displayName,
              path: '/video',
              resumeKey: current.id,
              duration: const Duration(minutes: 20),
              metadataContext: VideoMetadataContext(
                titleId: _title.id,
                displayTitle: _title.displayTitle,
                seasonNumber: 2,
                episodeNumber: 74,
                revision: 0,
              ),
            ),
            position: const Duration(minutes: 9, seconds: 21),
            updatedAt: DateTime.now(),
          );
          SharedPreferences.setMockInitialValues({
            'dreamplayer.continueWatching': jsonEncode([entry.toJson()]),
          });
          final library = UnifiedLibraryService.instance;
          final previous = library.snapshot;
          library.snapshot = LibrarySnapshot(
            titles: {_title.id: _title},
            episodes: {
              _episode.id: _episode,
              for (final episode in episodes) episode.id: episode,
            },
            files: {
              ..._snapshot.files,
              for (final episode in episodes)
                episode.id: MediaFile(
                  id: episode.id,
                  rootIds: const {'root'},
                  sourceRef: _source,
                  originalFileName: '${episode.id}.mp4',
                  titleId: _title.id,
                  episodeId: episode.id,
                  legacyResumeKey: episode.id,
                ),
            },
          );
          addTearDown(() => library.snapshot = previous);
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: scale == 1 ? ThemeData.light() : ThemeData.dark(),
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                ),
                child: UnifiedTitleDetailsScreen(titleId: _title.id),
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(find.text('播放第 74 集  09:21'), findsOneWidget);
          final target = find.byKey(ValueKey('rail-${current.id}'));
          if (target.evaluate().isEmpty) {
            // Bring the horizontal rail into the vertical viewport without
            // calling ensureVisible on the target itself. Doing that would
            // also move the rail horizontally and invalidate the centering
            // behavior this test is checking.
            await tester.drag(
              find.byType(CustomScrollView),
              Offset(0, -size.height),
            );
            await tester.pump();
          }
          await tester.pump();
          expect(
            (tester.getCenter(target).dx - size.width / 2).abs(),
            lessThan(1),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final size in [const Size(390, 844), const Size(1100, 700)]) {
    testWidgets('renders screenshot-style details without overflow at $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final library = UnifiedLibraryService.instance;
      final previous = library.snapshot;
      library.snapshot = _snapshot;
      addTearDown(() => library.snapshot = previous);

      await tester.pumpWidget(
        MaterialApp(
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData.dark(),
          home: MediaQuery(
            data: MediaQueryData(size: size),
            child: const UnifiedTitleDetailsScreen(titleId: 'tmdb:tv:229192'),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('沧元图'), findsOneWidget);
      expect(find.text('第 1 季'), findsOneWidget);
      expect(find.text('1. 第一集'), findsOneWidget);
      if (find.textContaining('重复版本未展开显示').evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          find.textContaining('重复版本未展开显示'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
      }
      expect(find.textContaining('重复版本未展开显示'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

const _title = MediaTitle(
  id: 'tmdb:tv:229192',
  kind: MediaTitleKind.tv,
  tmdbId: 229192,
  displayTitle: '沧元图',
  releaseDate: '2023-06-22',
  genres: ['动画', '动作', '冒险'],
  overview: '沧元界妖邪作乱，主角孟川为母复仇并守护苍生。',
  rating: 8.5,
  totalEpisodeCount: 52,
);

const _episode = LibraryEpisode(
  id: 'tmdb:tv:229192:s1:e1',
  titleId: 'tmdb:tv:229192',
  seasonNumber: 1,
  episodeNumber: 1,
  displayName: '第一集',
  runtime: Duration(minutes: 24),
);

const _source = MediaSourceRef(
  sourceId: 'webdav:server',
  sourceType: 'webdav',
  path: '/TV/沧元图/沧元图.S01E01.mp4',
  serverId: 'server',
);

final _snapshot = LibrarySnapshot(
  titles: const {'tmdb:tv:229192': _title},
  episodes: const {'tmdb:tv:229192:s1:e1': _episode},
  files: {
    'version-a': MediaFile(
      id: 'version-a',
      rootIds: const {'root'},
      sourceRef: _source,
      originalFileName: '沧元图.S01E01.2160p.mp4',
      titleId: _title.id,
      episodeId: _episode.id,
      availability: MediaAvailability.available,
      legacyResumeKey: 'webdav:episode:1:a',
    ),
    'version-b': MediaFile(
      id: 'version-b',
      rootIds: const {'root'},
      sourceRef: _source,
      originalFileName: '沧元图.S01E01.1080p.mp4',
      titleId: _title.id,
      episodeId: _episode.id,
      availability: MediaAvailability.available,
      legacyResumeKey: 'webdav:episode:1:b',
    ),
  },
);

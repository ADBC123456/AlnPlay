import 'package:dream_player/library/episode_target.dart';
import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/repository/library_repository.dart';
import 'package:dream_player/library/title_playback_preferences.dart';
import 'package:dream_player/library/unified_library_service.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/continue_watching.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

LibraryEpisode episode(int number, {int? season = 1}) => LibraryEpisode(
  id: 's$season:e$number',
  titleId: 'show',
  seasonNumber: season,
  episodeNumber: number,
  displayName: 'Episode $number',
);

MediaFile file(
  LibraryEpisode episode, {
  String suffix = '',
  MediaAvailability availability = MediaAvailability.available,
}) => MediaFile(
  id: '${episode.id}$suffix',
  rootIds: const {'root'},
  sourceRef: const MediaSourceRef(
    sourceId: 'local',
    sourceType: 'local',
    path: '/video',
  ),
  originalFileName: '${episode.id}.mkv',
  titleId: 'show',
  episodeId: episode.id,
  legacyResumeKey: '${episode.id}$suffix',
  availability: availability,
);

ContinueWatchingEntry progress(
  LibraryEpisode episode,
  int timestamp, {
  Duration position = const Duration(minutes: 9, seconds: 21),
}) => ContinueWatchingEntry(
  video: VideoItem(
    id: episode.id,
    title: episode.displayName,
    path: '/video',
    resumeKey: episode.id,
    duration: const Duration(minutes: 20),
    metadataContext: VideoMetadataContext(
      titleId: 'show',
      displayTitle: 'Show',
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      revision: 0,
    ),
  ),
  position: position,
  updatedAt: DateTime.fromMillisecondsSinceEpoch(timestamp),
);

LibrarySnapshot snapshot(
  List<LibraryEpisode> episodes, {
  List<MediaFile>? files,
}) => LibrarySnapshot(
  episodes: {for (final e in episodes) e.id: e},
  files: {for (final f in files ?? episodes.map(file)) f.id: f},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('groups use actual numbers, correct boundaries, unknown separately', () {
    final groups = groupEpisodes(
      [0, 1, 50, 51, 74, 100, 101, 206].map(episode).toList(),
    );
    expect(groups.map((group) => group.label), [
      '1–50',
      '51–100',
      '101–150',
      '201–206',
      '未知集号',
    ]);
    expect(groups[1].episodes.map((e) => e.episodeNumber), [51, 74, 100]);
  });
  test('recent actual viewing wins over highest number and maps season', () {
    final a = episode(74, season: 2), b = episode(100), c = episode(74);
    final target = resolveEpisodeTarget(
      snapshot: snapshot([a, b, c]),
      titleId: 'show',
      progress: [progress(b, 1), progress(a, 2)],
    );
    expect(target?.episode.id, a.id);
    expect(target?.progress?.position, const Duration(minutes: 9, seconds: 21));
  });
  test('legacy keys without metadata still map stable episode identity', () {
    final a = episode(74);
    final entry = ContinueWatchingEntry(
      video: VideoItem(
        id: 'legacy',
        duration: Duration.zero,
        title: 'legacy',
        resumeKey: a.id,
        path: '/legacy',
      ),
      position: const Duration(minutes: 5),
      updatedAt: DateTime.now(),
    );
    expect(
      resolveEpisodeTarget(
        snapshot: snapshot([a]),
        titleId: 'show',
        progress: [entry],
      )?.episode.id,
      a.id,
    );
  });
  test(
    'missing version uses same episode, never borrows old file progress',
    () {
      final a = episode(74), b = episode(75);
      final target = resolveEpisodeTarget(
        snapshot: snapshot(
          [a, b],
          files: [
            file(a, availability: MediaAvailability.missing),
            file(a, suffix: ':other'),
            file(b),
          ],
        ),
        titleId: 'show',
        progress: [progress(a, 2)],
      );
      expect(target?.episode.id, a.id);
      expect(target?.file.id, '${a.id}:other');
      expect(target?.progress, isNull);
    },
  );
  test(
    'missing episode skips forward and no history starts regular season',
    () {
      final special = episode(1, season: 0), a = episode(74), b = episode(75);
      final data = snapshot(
        [special, a, b],
        files: [
          file(special),
          file(a, availability: MediaAvailability.missing),
          file(b),
        ],
      );
      expect(
        resolveEpisodeTarget(
          snapshot: data,
          titleId: 'show',
          progress: [progress(a, 2)],
        )?.episode.id,
        b.id,
      );
      expect(
        resolveEpisodeTarget(
          snapshot: data,
          titleId: 'show',
          progress: [],
        )?.episode.id,
        b.id,
      );
    },
  );
  test('completed entry recommends next, completed final permits replay', () {
    final a = episode(74), b = episode(75);
    expect(
      resolveEpisodeTarget(
        snapshot: snapshot([a, b]),
        titleId: 'show',
        progress: [progress(a, 1, position: const Duration(minutes: 20))],
      )?.episode.id,
      b.id,
    );
    final replay = resolveEpisodeTarget(
      snapshot: snapshot([a]),
      titleId: 'show',
      progress: [progress(a, 1, position: const Duration(minutes: 20))],
    );
    expect(replay?.episode.id, a.id);
    expect(replay?.progress, isNull);
  });
  test('removed completed resume uses last watched preference', () {
    final a = episode(74), b = episode(75);
    final target = resolveEpisodeTarget(
      snapshot: snapshot([a, b]),
      titleId: 'show',
      progress: [],
      watchedKeys: {a.id},
      preference: TitlePlaybackPreference(
        titleId: 'show',
        lastPlayedFileId: a.id,
        lastPlayedEpisodeId: a.id,
        lastPlayedAt: DateTime.now(),
      ),
    );
    expect(target?.episode.id, b.id);
  });
  test(
    'actual progress saves latest identity; trivial open leaves it alone',
    () async {
      SharedPreferences.setMockInitialValues({});
      final a = episode(74), b = episode(75);
      final library = UnifiedLibraryService.instance;
      final previous = library.snapshot;
      library.snapshot = snapshot([a, b]);
      addTearDown(() => library.snapshot = previous);
      await ContinueWatchingStore.save(
        progress(a, 1).video,
        const Duration(minutes: 9),
      );
      final first = await TitlePlaybackPreferences.load('show');
      expect(first?.lastPlayedEpisodeId, a.id);
      await ContinueWatchingStore.save(progress(b, 2).video, Duration.zero);
      await TitlePlaybackPreferences.save(
        titleId: 'show',
        preferredSourceId: 'other',
      );
      final after = await TitlePlaybackPreferences.load('show');
      expect(after?.lastPlayedEpisodeId, a.id);
      expect(after?.lastPlayedAt, first?.lastPlayedAt);
    },
  );
}

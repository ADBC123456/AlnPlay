import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dream_player/library/metadata/library_metadata_resolver.dart';
import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/repository/library_repository.dart';
import 'package:dream_player/services/tmdb_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory directory;
  late JsonLibraryRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('library-resolver-');
    repository = JsonLibraryRepository(storageDirectory: directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('shares lookup work and stores official episode context', () async {
    final api = _ControlledApi();
    final resolver = TmdbLibraryMetadataResolver(
      repository: repository,
      api: api,
    );
    final file = _file('Show.S01E02.mkv');

    final first = resolver.resolve(
      file,
      const DiscoveryContext(directoryNames: []),
    );
    final second = resolver.resolve(
      file,
      const DiscoveryContext(directoryNames: []),
    );
    await _waitFor(() => api.searchCalls == 1);
    api.searchResult.complete(const [
      TmdMovie(
        id: 42,
        title: 'Show',
        originalTitle: 'Original Show',
        kind: TmdKind.tv,
      ),
    ]);
    await _waitFor(() => api.detailsCalls == 1);
    api.detailsResult.complete(
      const TmdDetails(
        title: 'Show',
        overview: 'Official overview',
        numberOfEpisodes: 12,
      ),
    );
    await _waitFor(() => api.seasonCalls == 1);
    api.seasonResult.complete(const [
      TmdEpisode(
        episodeNumber: 2,
        name: 'The Second Episode',
        runtimeMinutes: 24,
      ),
    ]);

    final results = await Future.wait([first, second]);
    expect(api.searchCalls, 1);
    expect(api.detailsCalls, 1);
    expect(api.seasonCalls, 1);
    for (final result in results) {
      expect(result.file.titleId, 'tmdb:tv:42');
      expect(result.file.episodeId, 'tmdb:tv:42:s1:e2');
      expect(result.file.identificationState, MetadataState.matched);
      expect(result.title?.totalEpisodeCount, 12);
      expect(result.episode?.displayName, 'The Second Episode');
      expect(result.episode?.runtime, const Duration(minutes: 24));
    }
  });

  test('ambiguous candidates stay in needs-review state', () async {
    final resolver = TmdbLibraryMetadataResolver(
      repository: repository,
      api: _ImmediateApi(const [
        TmdMovie(id: 1, title: 'Show', kind: TmdKind.tv),
        TmdMovie(id: 2, title: 'Show', kind: TmdKind.tv),
      ]),
    );

    final result = await resolver.resolve(
      _file('Show.S01E01.mkv'),
      const DiscoveryContext(directoryNames: []),
    );

    expect(result.file.identificationState, MetadataState.needsReview);
    expect(result.file.titleId, isNull);
  });

  test(
    'confirmed folder match is reused without searching each file',
    () async {
      const rootId = 'folder-pinned-root';
      await TmdService.instance.setManualFolder(
        'folder:$rootId',
        const TmdMovie(
          id: 229192,
          title: '沧元图',
          kind: TmdKind.tv,
          posterPath: '/poster.jpg',
        ),
      );
      final api = _FolderPinnedApi();
      final resolver = TmdbLibraryMetadataResolver(
        repository: repository,
        api: api,
      );

      final result = await resolver.resolve(
        _file('沧元图.S01E03.mp4'),
        const DiscoveryContext(rootId: rootId, directoryNames: ['沧元图']),
      );

      expect(api.searchCalls, 0);
      expect(result.file.titleId, 'tmdb:tv:229192');
      expect(result.file.episodeId, 'tmdb:tv:229192:s1:e3');
      expect(result.title?.displayTitle, '沧元图');
      expect(result.episode?.displayName, '第三集');
    },
  );

  test(
    'manual binding wins before API configuration and survives resolve',
    () async {
      const title = MediaTitle(
        id: 'tmdb:tv:77',
        kind: MediaTitleKind.tv,
        tmdbId: 77,
        displayTitle: 'Pinned Show',
      );
      final file = _file('unknown-002.mkv');
      await repository.applyScanBatch(
        ScanBatch(
          rootId: 'root',
          generation: 'g',
          isStart: true,
          files: [file],
          titles: const [title],
        ),
      );
      await repository.applyOverrides(const [
        LibraryOverride(
          fileId: 'local:unknown-002.mkv',
          pinnedTitleId: 'tmdb:tv:77',
          seasonNumber: 0,
          episodeNumber: 2,
        ),
      ]);
      final resolver = TmdbLibraryMetadataResolver(
        repository: repository,
        api: TmdApi(apiKey: ''),
      );

      final result = await resolver.resolve(
        file,
        const DiscoveryContext(directoryNames: []),
      );

      expect(result.file.matchOrigin, MatchOrigin.manual);
      expect(result.file.titleId, title.id);
      expect(result.file.episodeId, '${title.id}:s0:e2');
      expect(result.title?.displayTitle, 'Pinned Show');
    },
  );

  test(
    'numeric episode without a season directory defaults to season 1',
    () async {
      final api = _FolderPinnedApi();
      final resolver = TmdbLibraryMetadataResolver(
        repository: repository,
        api: api,
      );

      final result = await resolver.resolve(
        _file('03.mkv'),
        const DiscoveryContext(directoryNames: ['凡人修仙传']),
      );

      expect(api.searchCalls, greaterThan(0));
      if (result.file.episodeId != null) {
        expect(result.file.episodeId, endsWith(':s1:e3'));
      }
    },
  );
}

MediaFile _file(String name) => MediaFile(
  id: 'local:$name',
  rootIds: const {'root'},
  sourceRef: MediaSourceRef(
    sourceId: 'files',
    sourceType: 'files',
    path: '/video/$name',
  ),
  originalFileName: name,
  legacyResumeKey: '/video/$name',
);

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

class _ControlledApi extends TmdApi {
  _ControlledApi() : super(apiKey: 'test');

  final searchResult = Completer<List<TmdMovie>>();
  final detailsResult = Completer<TmdDetails>();
  final seasonResult = Completer<List<TmdEpisode>>();
  int searchCalls = 0;
  int detailsCalls = 0;
  int seasonCalls = 0;

  @override
  Future<List<TmdMovie>> search(
    String query, {
    int? year,
    TmdKind kind = TmdKind.movie,
  }) {
    searchCalls++;
    return searchResult.future;
  }

  @override
  Future<TmdDetails> details(TmdMovie movie) {
    detailsCalls++;
    return detailsResult.future;
  }

  @override
  Future<List<TmdEpisode>> seasonEpisodes(TmdMovie movie, int seasonNumber) {
    seasonCalls++;
    return seasonResult.future;
  }
}

class _ImmediateApi extends TmdApi {
  _ImmediateApi(this.results) : super(apiKey: 'test');

  final List<TmdMovie> results;

  @override
  Future<List<TmdMovie>> search(
    String query, {
    int? year,
    TmdKind kind = TmdKind.movie,
  }) async => results;
}

class _FolderPinnedApi extends TmdApi {
  _FolderPinnedApi() : super(apiKey: 'test');

  int searchCalls = 0;

  @override
  Future<List<TmdMovie>> search(
    String query, {
    int? year,
    TmdKind kind = TmdKind.movie,
  }) async {
    searchCalls++;
    return const [];
  }

  @override
  Future<TmdDetails> details(TmdMovie movie) async => const TmdDetails(
    title: '沧元图',
    numberOfEpisodes: 52,
    genres: ['动画', '动作'],
  );

  @override
  Future<List<TmdEpisode>> seasonEpisodes(
    TmdMovie movie,
    int seasonNumber,
  ) async => const [TmdEpisode(episodeNumber: 3, name: '第三集')];
}

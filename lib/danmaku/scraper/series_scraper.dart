import 'dart:async';

import '../binding/danmaku_binding_store.dart';
import '../model/episode_title_classifier.dart';
import '../source/danmaku_source_registry.dart';
import 'episode_mapper.dart';
import 'scrape_store.dart' as store;
import 'scrape_state.dart';

/// Identity the Agent-B adapter can hash/match with (PRD 匹配优先级:
/// hash+文件名+大小 → hash+文件名 → 文件名+大小 → 剧名/季/集 文本匹配).
class VideoIdentity {
  const VideoIdentity({
    required this.fileName,
    this.fileHash,
    this.fileSize,
    this.seriesTitle,
    this.season,
    this.episode,
  });

  final String fileName;
  final String? fileHash;
  final int? fileSize;
  final String? seriesTitle;
  final int? season;
  final int? episode;

  VideoIdentity fromVideo(ScrapeVideo v, SeriesScope scope) => VideoIdentity(
    fileName: v.fileName,
    fileHash: v.fileHash,
    fileSize: v.sizeBytes,
    seriesTitle: scope.seriesTitle,
    season: v.season ?? scope.season,
    episode: v.episode,
  );
}

/// The Agent-B seam (danmu_api-compatible source adapter). The orchestrator
/// only talks to this interface, so B can ship its HTTP client without
/// touching anything here.
abstract interface class DanmakuScrapeSource {
  /// `GET /api/v2/search/episodes?anime={title}` — remote episode catalog.
  Future<List<DanmakuCatalogAnime>> searchEpisodes(
    String title, {
    DanmakuCancelToken? cancelToken,
  });

  /// `POST /api/v2/match` — per-file fallback when the catalog mapping is
  /// ambiguous or missing. Returns null when the server reports no match
  /// (`isMatched=false` / empty `matches`).
  Future<DanmakuEpisodeRef?> match(
    VideoIdentity video, {
    DanmakuCancelToken? cancelToken,
  });
}

/// The Agent-C seam (cache repository). Fetches comments for a resolved ref
/// and persists them under (source, baseUrl, videoKey, schemaVersion).
abstract interface class DanmakuScrapeRepository {
  /// True when a valid danmaku cache exists for [videoKey]. [forceRefresh]
  /// short-circuits the check (batch "重新刮削").
  Future<bool> hasValidCache(
    String videoKey, {
    bool forceRefresh = false,
    String? episodeId,
  });

  /// Downloads the comments for [ref] and caches them against [videoKey].
  /// Returns the stored comment count (0 = empty episode, still cached).
  Future<int> fetchAndCache(
    DanmakuEpisodeRef ref,
    String videoKey, {
    DanmakuCancelToken? cancelToken,
  });
}

/// Result of one batch run.
class SeriesScrapeResult {
  const SeriesScrapeResult({required this.completed, required this.generation});

  final bool completed;
  final int generation;
}

/// Whole-series danmaku scrape orchestrator (PRD 当前剧集一键刮削).
///
/// - One catalog request up front (`searchEpisodes(scope.seriesTitle)`); each
///   video first maps via precise S/E numbers, falls back to /match.
/// - Concurrency limited to [maxConcurrency] (default 2) with a per-source
///   pacing gap between request starts (default 300–500 ms; clamped).
/// - 429/5xx/timeout ([DanmakuScrapeException.retryable] and unknown network
///   errors) retried [maxRetries] times with exponential backoff; non-retryable
///   failures (401/403-style) fail immediately.
/// - One episode failing never blocks the others.
/// - [cancel] and generation guards keep stale results from writing back; every
///   terminal episode state is persisted through [ScrapeStore] so an app
///   restart restores cached/failed results.
class SeriesScraper {
  SeriesScraper({
    required this.source,
    required this.repository,
    this.maxConcurrency = 2,
    this.minRequestGap = const Duration(milliseconds: 300),
    this.maxRetries = 2,
    this.backoffBase = const Duration(milliseconds: 600),
    this.backoffMax = const Duration(seconds: 3),
    this.onChanged,
  });
  final void Function()? onChanged;
  final DanmakuScrapeSource source;
  final DanmakuScrapeRepository repository;
  final int maxConcurrency;
  final Duration minRequestGap;
  final int maxRetries;
  final Duration backoffBase;
  final Duration backoffMax;

  SeriesScrapeState? _state;
  int _generation = 0;
  bool _cancelRequested = false;
  DanmakuCancelToken? _cancelToken;
  String? _selectedAnimeId;
  String? _selectedAnimeTitle;
  int _selectedEpisodeOffset = 0;

  /// Live state for the UI (read-only consumption; mutate via the scraper).
  SeriesScrapeState? get state => _state;

  /// Restores the last persisted terminal snapshot for this source/series.
  /// Transient rows are normalized to pending by [ScrapeStore].
  Future<SeriesScrapeState?> restore(
    SeriesScope scope, {
    List<ScrapeVideo> videos = const <ScrapeVideo>[],
  }) async {
    final restored = await store.ScrapeStore.loadTask(scope);
    if (restored == null && videos.isEmpty) return null;

    // One-time migration for matches saved by versions before bindings were
    // separated from scrape/download task state.
    final persisted = await DanmakuBindingStore.loadForScope(
      scope,
      videoIdentities: <String>{
        ...videos.map((video) => video.key),
        ...?restored?.episodes.map((episode) => episode.key),
      },
    );
    final legacy = <String, DanmakuEpisodeRef>{};
    for (final episode in restored?.episodes ?? const <ScrapeEpisodeState>[]) {
      if (episode.ref != null && !persisted.containsKey(episode.key)) {
        legacy[episode.key] = episode.ref!;
      }
    }
    if (legacy.isNotEmpty) {
      await DanmakuBindingStore.saveAll(scope, legacy, manual: false);
      persisted.addAll(
        await DanmakuBindingStore.loadForScope(
          scope,
          videoIdentities: legacy.keys,
        ),
      );
    }

    final obsoletePreviewBindings = persisted.entries
        .where(
          (entry) =>
              !entry.value.manual &&
              isDanmakuPromotionalEpisodeTitle(
                entry.value.ref.episodeTitle ?? '',
              ),
        )
        .map((entry) => entry.key)
        .toList();
    for (final key in obsoletePreviewBindings) {
      await DanmakuBindingStore.remove(
        sourceId: scope.sourceId,
        sourceBaseUrl: scope.sourceBaseUrl,
        videoIdentity: key,
      );
      persisted.remove(key);
    }

    final existingByKey = <String, ScrapeEpisodeState>{
      for (final episode in restored?.episodes ?? const <ScrapeEpisodeState>[])
        episode.key: episode,
    };
    final state = videos.isEmpty
        ? restored!
        : SeriesScrapeState(
            scope: scope,
            generation: restored?.generation ?? 0,
            selectedAnimeId: restored?.selectedAnimeId,
            selectedAnimeTitle: restored?.selectedAnimeTitle,
            selectedEpisodeOffset: restored?.selectedEpisodeOffset ?? 0,
            episodes: [
              for (final video in videos)
                _restoredRow(
                  video,
                  existingByKey[video.key],
                  persisted[video.key],
                ),
            ],
          );
    _state = state;
    _generation = state.generation;
    _selectedAnimeId = state.selectedAnimeId;
    _selectedAnimeTitle = state.selectedAnimeTitle;
    _selectedEpisodeOffset = state.selectedEpisodeOffset;
    _cancelRequested = false;
    _notify();
    return state;
  }

  static ScrapeEpisodeState _restoredRow(
    ScrapeVideo video,
    ScrapeEpisodeState? previous,
    DanmakuBinding? binding,
  ) {
    if (binding != null) {
      final sameCachedEpisode =
          previous?.ref?.episodeId == binding.ref.episodeId &&
          (previous?.status == ScrapeStatus.cached ||
              previous?.status == ScrapeStatus.success ||
              previous?.status == ScrapeStatus.empty);
      return ScrapeEpisodeState(
        key: video.key,
        fileName: video.fileName,
        season: video.season,
        episode: video.episode,
        status: sameCachedEpisode ? previous!.status : ScrapeStatus.matched,
        ref: binding.ref,
        commentCount: sameCachedEpisode ? previous?.commentCount : null,
        fetchedAt: sameCachedEpisode ? previous?.fetchedAt : null,
      );
    }
    return ScrapeEpisodeState(
      key: video.key,
      fileName: video.fileName,
      season: video.season,
      episode: video.episode,
      status:
          previous?.status == ScrapeStatus.failed ||
              previous?.status == ScrapeStatus.noMatch
          ? previous!.status
          : ScrapeStatus.pending,
      error: previous?.error,
    );
  }

  bool get _isStale => _cancelRequested;

  void _notify() => onChanged?.call();

  /// Starts (or restarts) the batch scrape for [videos] under [scope].
  ///
  /// Bumps the generation, invalidates any previous run, and returns when the
  /// whole batch reaches a terminal outcome. `forceRefresh` re-downloads
  /// episodes that already have a cache.
  Future<SeriesScrapeResult> start(
    SeriesScope scope,
    List<ScrapeVideo> videos, {
    bool forceRefresh = false,
    String? selectedAnimeId,
    String? selectedAnimeTitle,
    int? selectedEpisodeOffset,
  }) async {
    if (selectedAnimeId != null && selectedAnimeId.isNotEmpty) {
      _selectedAnimeId = selectedAnimeId;
      _selectedAnimeTitle = selectedAnimeTitle;
      _selectedEpisodeOffset = selectedEpisodeOffset ?? 0;
    }
    final generation = ++_generation;
    _cancelToken?.cancel();
    final cancelToken = DanmakuCancelToken();
    _cancelToken = cancelToken;
    _cancelRequested = false;
    final st = SeriesScrapeState(
      scope: scope,
      generation: generation,
      selectedAnimeId: _selectedAnimeId,
      selectedAnimeTitle: _selectedAnimeTitle,
      selectedEpisodeOffset: _selectedEpisodeOffset,
    );
    _state = st;

    final savedBindings = await DanmakuBindingStore.loadForScope(
      scope,
      videoIdentities: videos.map((video) => video.key),
    );

    st.phase = ScrapePhase.scanning;
    _notify();

    for (final v in videos) {
      final binding = savedBindings[v.key];
      st.episodes.add(
        ScrapeEpisodeState(
          key: v.key,
          fileName: v.fileName,
          status: binding == null ? ScrapeStatus.pending : ScrapeStatus.matched,
          season: v.season,
          episode: v.episode,
          ref: binding?.ref,
        ),
      );
    }
    await store.ScrapeStore.saveTask(st);
    _notify();

    // Resolve cache hits before touching the network. A fully scraped series
    // completes without even issuing the catalog search request.
    final pendingVideos = <ScrapeVideo>[];
    for (var i = 0; i < videos.length; i++) {
      var cached = false;
      try {
        cached = await repository.hasValidCache(
          videos[i].key,
          forceRefresh: forceRefresh,
          episodeId: savedBindings[videos[i].key]?.ref.episodeId,
        );
      } on Exception {
        // A cache read failure is a miss; the normal fetch path may repair it.
      }
      if (_isStale || generation != _generation) {
        return SeriesScrapeResult(completed: false, generation: generation);
      }
      if (cached && !forceRefresh) {
        st.episodes[i] = st.episodes[i].copyWith(status: ScrapeStatus.cached);
      } else {
        pendingVideos.add(videos[i]);
      }
    }
    _notify();
    await store.ScrapeStore.saveTask(st);
    if (pendingVideos.isEmpty) {
      st.phase = ScrapePhase.completed;
      _notify();
      await store.ScrapeStore.saveTask(st);
      return SeriesScrapeResult(completed: true, generation: generation);
    }

    // 1. Resolve a catalog only when at least one file has no saved binding
    // or holds an automatic one that must be revalidated. A fully manually
    // bound season can be pre-cached without repeating the search.
    List<DanmakuCatalogAnime> catalog = const [];
    final automaticKeys = <String>{
      for (final video in pendingVideos)
        if (savedBindings[video.key]?.manual == false) video.key,
    };
    final needsMatching = pendingVideos.any((video) {
      final row = st.episodes.firstWhere((episode) => episode.key == video.key);
      return row.ref == null || automaticKeys.contains(video.key);
    });
    if (needsMatching) {
      st.phase = ScrapePhase.matching;
      _notify();
      try {
        catalog = await _withRetry(
          () => source.searchEpisodes(
            scope.seriesTitle,
            cancelToken: cancelToken,
          ),
          cancelToken: cancelToken,
        );
      } on DanmakuScrapeException {
        if (_isStale || generation != _generation) {
          return SeriesScrapeResult(completed: false, generation: generation);
        }
        final anyUnbound = pendingVideos.any(
          (video) =>
              st.episodes.firstWhere((e) => e.key == video.key).ref == null,
        );
        if (anyUnbound) {
          st.phase = ScrapePhase.failed;
          _notify();
          await store.ScrapeStore.saveTask(st);
          return SeriesScrapeResult(completed: false, generation: generation);
        }
        // Only revalidation failed: keep the saved automatic bindings.
        catalog = const [];
      }
    }
    if (_isStale || generation != _generation) {
      return SeriesScrapeResult(completed: false, generation: generation);
    }

    // 2. Process episodes with bounded concurrency.
    st.phase = ScrapePhase.downloading;
    _notify();
    final videosList = pendingVideos;
    var nextIndex = 0;
    Future<void> worker() async {
      while (true) {
        if (_isStale || generation != _generation) return;
        final i = nextIndex++;
        if (i >= videosList.length) return;
        await _processOne(
          scope,
          videosList[i],
          catalog,
          st,
          generation,
          cancelToken,
          forceRefresh: forceRefresh,
          revalidateBinding: automaticKeys.contains(videosList[i].key),
        );
      }
    }

    // A manually selected catalog turns the run into comment downloads only.
    // Keep those serial: common public providers allow three comments calls
    // per rolling window and return 429 for even a small concurrent burst.
    final workerCount = _selectedAnimeId == null ? maxConcurrency : 1;
    final workers = List.generate(
      workerCount.clamp(1, videosList.isEmpty ? 1 : videosList.length),
      (_) => worker(),
      growable: false,
    );
    await Future.wait(workers);

    if (_isStale || generation != _generation) {
      st.phase = ScrapePhase.cancelled;
      _notify();
      await store.ScrapeStore.saveTask(st);
      return SeriesScrapeResult(completed: false, generation: generation);
    }

    st.phase = st.hasFailure || st.noMatchCount > 0
        ? ScrapePhase.partialFailure
        : ScrapePhase.completed;
    _notify();
    await store.ScrapeStore.saveTask(st);
    return SeriesScrapeResult(completed: true, generation: generation);
  }

  /// Loads the remote series candidates shown by the manual picker.
  Future<List<DanmakuCatalogAnime>> searchCandidates(SeriesScope scope) async {
    final token = DanmakuCancelToken();
    return _withRetry(
      () => source.searchEpisodes(scope.seriesTitle, cancelToken: token),
      cancelToken: token,
    );
  }

  /// Resolves and atomically saves a whole season's file-to-episode bindings.
  /// This method performs no comment downloads; playback loads a bound episode
  /// on demand and [start] remains the explicit whole-season pre-cache action.
  Future<int> bindSeries(
    SeriesScope scope,
    List<ScrapeVideo> videos,
    DanmakuCatalogAnime anime, {
    int episodeOffset = 0,
  }) async {
    _cancelToken?.cancel();
    _cancelRequested = false;
    _selectedAnimeId = anime.animeId;
    _selectedAnimeTitle = anime.animeTitle;
    _selectedEpisodeOffset = episodeOffset;
    final generation = ++_generation;
    final bindings = <String, DanmakuEpisodeRef>{};
    final rows = <ScrapeEpisodeState>[];
    for (final video in videos) {
      final ref = _mapFromCatalog(video, scope, <DanmakuCatalogAnime>[anime]);
      if (ref != null) bindings[video.key] = ref;
      rows.add(
        ScrapeEpisodeState(
          key: video.key,
          fileName: video.fileName,
          season: video.season,
          episode: video.episode,
          status: ref == null ? ScrapeStatus.noMatch : ScrapeStatus.matched,
          ref: ref,
        ),
      );
    }

    // One durable commit for the complete selection. Unmapped files in this
    // batch explicitly lose an older choice rather than retaining stale data.
    await DanmakuBindingStore.saveAll(
      scope,
      bindings,
      replaceVideoIdentities: videos.map((video) => video.key),
      manual: true,
    );
    final state = SeriesScrapeState(
      scope: scope,
      episodes: rows,
      generation: generation,
      selectedAnimeId: anime.animeId,
      selectedAnimeTitle: anime.animeTitle,
      selectedEpisodeOffset: episodeOffset,
    );
    state.phase = bindings.length == videos.length
        ? ScrapePhase.completed
        : ScrapePhase.partialFailure;
    _state = state;
    await store.ScrapeStore.saveTask(state);
    _notify();
    return bindings.length;
  }

  /// Rebinds one local file to an explicitly selected remote episode.
  /// Only the durable binding is changed here. The next playback loads its
  /// comments on demand; pre-caching is an explicit, separate operation.
  Future<void> manualMatchEpisode(
    SeriesScope scope,
    String videoKey,
    DanmakuEpisodeRef ref,
  ) async {
    final st = _requireSameScope(scope);
    final index = st.episodes.indexWhere((episode) => episode.key == videoKey);
    if (index < 0) {
      throw StateError('episode is not part of the current scrape task');
    }
    final generation = ++_generation;
    _cancelToken?.cancel();
    _cancelRequested = false;
    st.generation = generation;
    await DanmakuBindingStore.save(scope, videoKey, ref, manual: true);
    st.episodes[index] = st.episodes[index].copyWith(
      status: ScrapeStatus.matched,
      ref: ref,
      clearError: true,
      clearCommentCount: true,
      clearFetchedAt: true,
    );
    st.phase = st.noMatchCount > 0
        ? ScrapePhase.partialFailure
        : ScrapePhase.completed;
    _notify();
    await store.ScrapeStore.saveTask(st);
  }

  /// Re-runs only failed/noMatch episodes. The retried subset runs through
  /// [start]; terminal states from the previous run are merged back so the
  /// task view still shows the whole series.
  Future<SeriesScrapeResult> retryFailed(SeriesScope scope) async {
    final previous = _requireSameScope(scope);
    final keep = previous.episodes
        .where(
          (e) =>
              e.status != ScrapeStatus.failed &&
              e.status != ScrapeStatus.noMatch,
        )
        .toList();
    final videos = <ScrapeVideo>[
      for (final e in previous.episodes)
        if (e.status == ScrapeStatus.failed || e.status == ScrapeStatus.noMatch)
          ScrapeVideo(
            key: e.key,
            fileName: e.fileName,
            season: e.season,
            episode: e.episode,
          ),
    ];
    if (videos.isEmpty) {
      return SeriesScrapeResult(completed: true, generation: _generation);
    }
    final result = await start(scope, videos, forceRefresh: false);
    if (!result.completed) return result;

    // Merge: previous keepers + the freshly retried rows.
    final st = _state!;
    final merged = [...keep, ...st.episodes];
    st.episodes
      ..clear()
      ..addAll(merged);
    _notify();
    await store.ScrapeStore.saveTask(st);
    return result;
  }

  /// Cancels the active run. In-flight episodes flip to [ScrapeStatus.cancelled].
  Future<void> cancel() async {
    _cancelRequested = true;
    _cancelToken?.cancel();
    final st = _state;
    if (st == null) return;
    var dirty = false;
    for (var i = 0; i < st.episodes.length; i++) {
      final s = st.episodes[i].status;
      if (s == ScrapeStatus.pending ||
          s == ScrapeStatus.matched ||
          s == ScrapeStatus.fetching) {
        st.episodes[i] = st.episodes[i].copyWith(
          status: ScrapeStatus.cancelled,
        );
        dirty = true;
      }
    }
    if (dirty) {
      st.phase = ScrapePhase.cancelled;
      _notify();
      await store.ScrapeStore.saveTask(st);
    }
  }

  SeriesScrapeState _requireSameScope(SeriesScope scope) {
    final st = _state;
    if (st == null || st.scope.storeKey != scope.storeKey) {
      throw StateError('no active run for this scope; call start() first');
    }
    return st;
  }

  Future<void> _processOne(
    SeriesScope scope,
    ScrapeVideo video,
    List<DanmakuCatalogAnime> catalog,
    SeriesScrapeState st,
    int generation,
    DanmakuCancelToken cancelToken, {
    required bool forceRefresh,
    bool revalidateBinding = false,
  }) async {
    final idx = st.episodes.indexWhere((e) => e.key == video.key);
    if (idx < 0) return;

    // An automatic binding whose episodeId no longer exists in the remote
    // catalog is stale: drop it so the current rules can remap the file.
    // Manual bindings are never revalidated.
    final savedRef = st.episodes[idx].ref;
    if (revalidateBinding &&
        savedRef != null &&
        catalog.isNotEmpty &&
        !catalog.any(
          (anime) => anime.episodes.any(
            (episode) => episode.episodeId == savedRef.episodeId,
          ),
        )) {
      st.episodes[idx] = ScrapeEpisodeState(
        key: video.key,
        fileName: video.fileName,
        season: video.season,
        episode: video.episode,
        status: ScrapeStatus.pending,
      );
    }

    // 1. Cache check — skip already-scraped episodes unless forced.
    final cached = await repository.hasValidCache(
      video.key,
      forceRefresh: forceRefresh,
      episodeId: st.episodes[idx].ref?.episodeId,
    );
    if (_isStale || generation != _generation) return;
    if (cached && !forceRefresh) {
      st.episodes[idx] = st.episodes[idx].copyWith(status: ScrapeStatus.cached);
      _notify();
      await store.ScrapeStore.saveTask(st);
      return;
    }
    DanmakuEpisodeRef? ref = st.episodes[idx].ref;
    final hadSavedBinding = ref != null;
    var matchAttempted = false;
    Future<DanmakuEpisodeRef?> requestMatch() async {
      matchAttempted = true;
      await _pace();
      if (_isStale || generation != _generation) return null;
      return _withRetry<DanmakuEpisodeRef?>(
        () => source.match(
          VideoIdentity(
            fileName: video.fileName,
            fileHash: video.fileHash,
            fileSize: video.sizeBytes,
            seriesTitle: scope.seriesTitle,
            season: video.season ?? scope.season,
            episode: video.episode,
          ),
          cancelToken: cancelToken,
        ),
        cancelToken: cancelToken,
      );
    }

    try {
      // A content hash is stronger than title/catalog heuristics. Remote
      // files without a hash use the catalog first to avoid one match request
      // per episode.
      if (ref == null && video.fileHash?.isNotEmpty == true) {
        ref = await requestMatch();
      }
      ref ??= _mapFromCatalog(video, scope, catalog);
      if (ref == null && !matchAttempted) {
        ref = await requestMatch();
      }
    } on DanmakuScrapeException catch (e) {
      if (_isStale || generation != _generation) return;
      st.episodes[idx] = st.episodes[idx].copyWith(
        status: ScrapeStatus.failed,
        error: e.message,
      );
      _notify();
      await store.ScrapeStore.saveTask(st);
      return;
    }
    if (_isStale || generation != _generation) return;

    if (ref == null) {
      st.episodes[idx] = st.episodes[idx].copyWith(
        status: ScrapeStatus.noMatch,
      );
      _notify();
      await store.ScrapeStore.saveTask(st);
      return;
    }

    st.episodes[idx] = st.episodes[idx].copyWith(
      status: ScrapeStatus.matched,
      ref: ref,
      clearError: true,
    );
    if (!hadSavedBinding) {
      await DanmakuBindingStore.save(scope, video.key, ref, manual: false);
    }
    _notify();

    // 3. Fetch + cache.
    st.episodes[idx] = st.episodes[idx].copyWith(status: ScrapeStatus.fetching);
    _notify();
    await _pace();
    if (_isStale || generation != _generation) return;
    try {
      final count = await _withRetry<int>(
        () =>
            repository.fetchAndCache(ref!, video.key, cancelToken: cancelToken),
        cancelToken: cancelToken,
      );
      if (_isStale || generation != _generation) return;
      st.episodes[idx] = st.episodes[idx].copyWith(
        status: count > 0 ? ScrapeStatus.success : ScrapeStatus.empty,
        commentCount: count,
        error: null,
        fetchedAt: DateTime.now(),
      );
    } on DanmakuScrapeException catch (e) {
      if (_isStale || generation != _generation) return;
      st.episodes[idx] = st.episodes[idx].copyWith(
        status: ScrapeStatus.failed,
        error: e.message,
      );
    }
    _notify();
    await store.ScrapeStore.saveTask(st);
  }

  /// Precise S/E mapping against the catalog; null → needs /match.
  DanmakuEpisodeRef? _mapFromCatalog(
    ScrapeVideo video,
    SeriesScope scope,
    List<DanmakuCatalogAnime> catalog,
  ) {
    if (catalog.isEmpty) return null;

    final DanmakuCatalogAnime anime;
    final selectedId = _selectedAnimeId;
    if (selectedId != null) {
      final selected = catalog.where((item) => item.animeId == selectedId);
      if (selected.length != 1) return null;
      anime = selected.single;
    } else if (catalog.length == 1) {
      anime = catalog.single;
    } else {
      final expectedSeason = video.season ?? scope.season;
      if (expectedSeason == null) return null;
      final seasonMatches = catalog
          .where(
            (candidate) =>
                _seasonFromTitle(candidate.animeTitle) == expectedSeason,
          )
          .toList();
      if (seasonMatches.length != 1) return null;
      anime = seasonMatches.single;
    }
    if (anime.episodes.isEmpty) return null;

    final parsed = DanmakuEpisodeParser.parse(
      video.fileName,
      folderName: (video.season ?? scope.season) == null
          ? null
          : 'Season ${video.season ?? scope.season}',
    );
    // The user-selected offset applies whether the episode number came from
    // the library or from the numeric filename rule (`001.mkv`).
    final indexedEpisode = video.episode != null
        ? video.episode! + _selectedEpisodeOffset
        : parsed.isNumbered && _selectedEpisodeOffset != 0
        ? parsed.episode + _selectedEpisodeOffset
        : null;
    final info = indexedEpisode == null
        ? parsed
        : EpisodeInfo(
            source: video.season == null
                ? EpisodeSource.episodeOnly
                : EpisodeSource.seasonEpisode,
            season: video.season ?? scope.season ?? parsed.season,
            episode: indexedEpisode,
            seriesName: parsed.seriesName,
          );
    final mapped = DanmuEpisodeMapper.match(info, [
      for (final episode in anime.episodes)
        DanmuCatalogEpisode(
          episodeId: episode.episodeId,
          episodeTitle: episode.episodeTitle,
          animeId: anime.animeId,
          animeTitle: anime.animeTitle,
          episodeNumber:
              episode.episodeNumber ??
              DanmakuEpisodeParser.parse(episode.episodeTitle).episode,
        ),
    ], season: video.season ?? scope.season);

    DanmuCatalogEpisode? ep;
    if (mapped.status == EpisodeMatchStatus.mapped) {
      ep = mapped.episode;
    } else if (mapped.status == EpisodeMatchStatus.special) {
      final ranked = [
        for (final candidate in mapped.candidates)
          (
            candidate,
            DanmuEpisodeMapper.titleSimilarity(
              video.fileName,
              candidate.episodeTitle,
            ),
          ),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      if (ranked.isNotEmpty &&
          ranked.first.$2 >= 70 &&
          (ranked.length == 1 || ranked[1].$2 < ranked.first.$2)) {
        ep = ranked.first.$1;
      }
    }
    // Missing, duplicate and unresolved special rows deliberately fall back
    // to /match; the batch scraper never silently selects one candidate.
    if (ep == null) return null;

    return DanmakuEpisodeRef(
      animeId: anime.animeId,
      episodeId: ep.episodeId,
      animeTitle: anime.animeTitle,
      episodeTitle: ep.episodeTitle,
    );
  }

  int? _seasonFromTitle(String title) {
    final m = RegExp(
      r'(?:\bS(?:eason)?\s*0*(\d+)\b)|(?:第\s*(\d+)\s*[季部])',
      caseSensitive: false,
    ).firstMatch(title);
    if (m == null) return null;
    return int.tryParse(m.group(1) ?? m.group(2) ?? '');
  }

  /// Serialises request starts so the source sees ≥[minRequestGap] between
  /// them (PRD: 同一 source 请求间隔 300~500ms; clamped to that window).
  Future<void> _pace() async {
    // Workers may reach this method in the same event-loop turn. Reserve a
    // queue slot synchronously before awaiting, otherwise both observe the
    // same [_lastRequest] and issue requests together (real danmu_api servers
    // answer that burst with HTTP 429).
    final previous = _paceQueue;
    final done = Completer<void>();
    _paceQueue = done.future;
    await previous;
    try {
      await _paceReservedRequest();
    } finally {
      done.complete();
    }
  }

  Future<void> _paceReservedRequest() async {
    final gap = minRequestGap < const Duration(milliseconds: 300)
        ? const Duration(milliseconds: 300)
        : (minRequestGap > const Duration(milliseconds: 500)
              ? const Duration(milliseconds: 500)
              : minRequestGap);
    final now = DateTime.now();
    final last = _lastRequest;
    if (last != null) {
      final elapsed = now.difference(last);
      if (elapsed < gap) {
        await Future<void>.delayed(gap - elapsed);
      }
    }
    _lastRequest = DateTime.now();
  }

  DateTime? _lastRequest;
  Future<void> _paceQueue = Future<void>.value();

  /// Retry wrapper: retryable exceptions (429/5xx/timeout) get exponential
  /// backoff up to [maxRetries]; non-retryable fail immediately. After the
  /// last attempt the last exception is rethrown.
  Future<T> _withRetry<T>(
    Future<T> Function() op, {
    required DanmakuCancelToken cancelToken,
  }) async {
    var attempt = 0;
    while (true) {
      if (cancelToken.isCancelled) {
        throw const DanmakuScrapeException('刮削已取消');
      }
      try {
        return await op();
      } on DanmakuScrapeException catch (e) {
        if (!e.retryable || attempt >= maxRetries) rethrow;
        await _waitForRetry(_backoffFor(attempt), cancelToken);
        attempt++;
      } on Exception {
        // Unknown network-layer exception (SocketException, TimeoutException…)
        // — treat like a retryable failure.
        if (attempt >= maxRetries) {
          throw const DanmakuScrapeException('网络请求失败');
        }
        await _waitForRetry(_backoffFor(attempt), cancelToken);
        attempt++;
      }
    }
  }

  Future<void> _waitForRetry(
    Duration delay,
    DanmakuCancelToken cancelToken,
  ) async {
    await Future.any<void>([
      Future<void>.delayed(delay),
      cancelToken.whenCancelled,
    ]);
    if (cancelToken.isCancelled) {
      throw const DanmakuScrapeException('刮削已取消');
    }
  }

  Duration _backoffFor(int attempt) {
    final ms = backoffBase.inMilliseconds * (1 << attempt);
    return Duration(milliseconds: ms.clamp(0, backoffMax.inMilliseconds));
  }
}

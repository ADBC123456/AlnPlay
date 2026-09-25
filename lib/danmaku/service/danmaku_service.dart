// DanmakuService: the single facade the UI talks to.
//
// Responsibilities:
//  - lifecycle: `init` at app startup loads persisted source configs and
//    registers one DanmuApiSource per config into the global registry;
//    `reconfigure` re-registers after add/edit/delete in Settings;
//  - single-video playback: `ensureForVideo` cache-first auto-match +
//    load, with a per-video in-flight future so concurrent callers share
//    one request (the same dedupe TmdService uses);
//  - model bridge: source comments -> DanmakuItemModel for the pipeline;
//  - series scrape: builds the DanmakuScrapeSource / DanmakuScrapeRepository
//    adapters over the real source + repository so the details screen can
//    run SeriesScraper unchanged.
//
// No network call here blocks playback: `ensureForVideo` is always
// fire-and-forget from the player's perspective (PRD "弹幕加载失败不能阻止
// 视频播放").

import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/video_item.dart';
import '../binding/danmaku_binding_store.dart';
import '../identity/video_identity.dart' as vid;
import '../model/episode_title_classifier.dart';
import '../models/danmaku_models.dart' as models;
import '../repository/danmaku_cache.dart';
import '../repository/danmaku_repository.dart';
import '../scraper/episode_mapper.dart' as mapper;
import '../scraper/scrape_state.dart' as scrape;
import '../scraper/scrape_store.dart' as scrape_store;
import '../scraper/series_scraper.dart';
import '../source/danmaku_source_registry.dart';
import '../source/danmaku_source_store.dart';
import '../source/danmu_api_source.dart';

/// Result of a completed single-video danmaku load.
class DanmakuLoadOutcome {
  const DanmakuLoadOutcome._({required this.status, this.items = const []});

  final DanmakuStatus status;
  final List<models.DanmakuItemModel> items;
}

/// Coarse per-video status surfaced to the player UI chip.
enum DanmakuStatus { idle, loading, ready, empty, noMatch, failed }

class DanmakuService {
  DanmakuService._()
    : cache = DanmakuCache(),
      _registry = DanmakuSourceRegistry.instance {
    repository = DanmakuRepository(cache: cache, registry: _registry);
  }

  /// Isolated service for widget/integration tests. It deliberately avoids
  /// path_provider and the process-global registry.
  DanmakuService.forTesting({
    List<DanmakuSourceConfig> configs = const [],
    this.enabled = true,
    Directory? cacheDirectory,
  }) : cache = DanmakuCache(
         directory:
             cacheDirectory ??
             Directory(
               '${Directory.systemTemp.path}${Platform.pathSeparator}'
               'dreamplayer_danmaku_test',
             ),
       ),
       _registry = DanmakuSourceRegistry() {
    repository = DanmakuRepository(cache: cache, registry: _registry);
    this.configs = List<DanmakuSourceConfig>.unmodifiable(configs);
    _initialized = true;
    _registerAll();
  }

  static final DanmakuService instance = DanmakuService._();

  final DanmakuCache cache;
  final DanmakuSourceRegistry _registry;
  late final DanmakuRepository repository;

  /// Loaded source configs (order = persistence order; priority lives on
  /// the config).
  List<DanmakuSourceConfig> configs = const [];

  /// Global show/hide switch.
  bool enabled = true;

  bool _initialized = false;
  Future<void>? _initFuture;

  /// Per-video in-flight loads, deduped by stable identity key.
  final Map<String, Future<DanmakuLoadOutcome>> _inFlight = {};
  final Map<String, Set<DanmakuProgressCallback>> _progressListeners = {};

  /// Idempotent; concurrent callers share one init future.
  Future<void> init() {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    try {
      cache.setDirectory((await createDefaultDanmakuCache()).root!);
    } catch (_) {
      cache.setDirectory(
        Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'dreamplayer_danmaku',
        ),
      );
    }
    try {
      configs = await DanmakuSourceStore.load();
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(kDanmakuEnabledPref) ?? true;
    } catch (_) {
      configs = const [];
      enabled = true;
    }
    _registerAll();
    _initialized = true;
  }

  void _registerAll() {
    for (final c in configs) {
      if (!c.enabled) continue;
      try {
        _registry.register(
          DanmuApiSource(
            DanmuApiConfig(
              baseUrl: c.baseUrl,
              token: c.token,
              sourceId: c.id,
              displayName: c.name,
            ),
          ),
          enabled: true,
          priority: c.priority,
        );
      } catch (_) {
        // Invalid baseUrl etc. — skip this source; Settings shows the error
        // via its own test-connection flow.
      }
    }
  }

  /// Re-registers every source after a Settings change. Unregisters
  /// everything first so removed sources disappear immediately.
  Future<void> reconfigure(List<DanmakuSourceConfig> newConfigs) async {
    await init();
    final oldIds = configs.map((config) => config.id).toSet();
    final replacement = List<DanmakuSourceConfig>.unmodifiable(newConfigs);
    for (final id in {...oldIds, ...replacement.map((config) => config.id)}) {
      _registry.unregister(id);
    }
    configs = replacement;
    _inFlight.clear();
    _progressListeners.clear();
    _registerAll();
    await DanmakuSourceStore.save(configs);
  }

  Future<void> setEnabled(bool value) async {
    await init();
    enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kDanmakuEnabledPref, value);
  }

  Future<void> clearCache() async {
    await init();
    _inFlight.clear();
    _progressListeners.clear();
    await Future.wait([
      cache.clearAll(),
      scrape_store.ScrapeStore.clearAllTasks(),
    ]);
  }

  /// The first enabled source (priority order), or null.
  DanmakuSourceConfig? get primarySource {
    final active = enabledSources;
    return active.isEmpty ? null : active.first;
  }

  List<DanmakuSourceConfig> get enabledSources {
    final active = configs.where((c) => c.enabled).toList()
      ..sort((a, b) => b.priority.compareTo(a.priority));
    return active;
  }

  /// Cache-first load for the video now playing. Returns a cached /
  /// freshly-fetched outcome; concurrent callers share one future per
  /// identity key, and a completed outcome is memoized so re-selecting the
  /// same video never re-requests.
  Future<DanmakuLoadOutcome> ensureForVideo(
    vid.VideoIdentity identity, {
    VideoMetadataContext? metadata,
    bool forceRefresh = false,
    DanmakuProgressCallback? onProgress,
  }) {
    if (!_initialized) {
      return init().then(
        (_) => ensureForVideo(
          identity,
          metadata: metadata,
          forceRefresh: forceRefresh,
          onProgress: onProgress,
        ),
      );
    }
    final key = metadata == null
        ? identity.stableKey
        : '${identity.stableKey}|${metadata.titleId}|${metadata.revision}';
    if (!forceRefresh) {
      final running = _inFlight[key];
      if (running != null) {
        if (onProgress != null) {
          (_progressListeners[key] ??= {}).add(onProgress);
        }
        return running;
      }
    } else {
      _inFlight.remove(key);
      _progressListeners.remove(key);
    }
    final listeners = <DanmakuProgressCallback>{?onProgress};
    _progressListeners[key] = listeners;
    void report(DanmakuLoadProgress progress) {
      // Capture this operation's listener set. A force-refresh can replace the
      // same key while this request is still finishing; looking the key up
      // again would leak old progress into the new request's UI.
      for (final listener in List<DanmakuProgressCallback>.of(listeners)) {
        try {
          listener(progress);
        } catch (_) {}
      }
    }

    late final Future<DanmakuLoadOutcome> future;
    future = _load(identity, metadata, report, forceRefresh: forceRefresh)
        .whenComplete(() {
          if (identical(_inFlight[key], future)) {
            _inFlight.remove(key);
            _progressListeners.remove(key);
          }
        });
    _inFlight[key] = future;
    return future;
  }

  Future<DanmakuLoadOutcome> _load(
    vid.VideoIdentity identity,
    VideoMetadataContext? metadata,
    DanmakuProgressCallback onProgress, {
    required bool forceRefresh,
  }) async {
    if (!enabled) {
      return const DanmakuLoadOutcome._(status: DanmakuStatus.idle);
    }
    final sources = enabledSources;
    if (sources.isEmpty) {
      return const DanmakuLoadOutcome._(status: DanmakuStatus.idle);
    }
    var sawFailure = false;
    var sawNoMatch = false;
    var sawEmpty = false;

    // A saved binding is authoritative and is checked across every enabled
    // deployment before filename/metadata matching. This prevents a higher
    // priority source from auto-matching the wrong series ahead of a user's
    // explicit choice on another source.
    var foundBinding = false;
    for (final source in sources) {
      onProgress(
        DanmakuLoadProgress(
          phase: DanmakuLoadPhase.matching,
          sourceId: source.id,
        ),
      );
      final binding = await DanmakuBindingStore.load(
        sourceId: source.id,
        sourceBaseUrl: source.baseUrl,
        videoIdentity: identity.stableKey,
      );
      if (binding == null) continue;
      if (!binding.manual &&
          isDanmakuPromotionalEpisodeTitle(binding.ref.episodeTitle ?? '')) {
        await DanmakuBindingStore.remove(
          sourceId: source.id,
          sourceBaseUrl: source.baseUrl,
          videoIdentity: identity.stableKey,
        );
        continue;
      }
      foundBinding = true;
      final result = await repository.loadForEpisode(
        sourceId: source.id,
        baseUrl: source.baseUrl,
        request: DanmakuVideoRequest(
          videoIdentity: identity.stableKey,
          fileName: identity.fileName,
          fileHash: identity.fileHash,
          fileSize: identity.fileSize,
          videoKey: identity.stableKey,
        ),
        episodeId: binding.ref.episodeId,
        shiftSeconds: binding.ref.shift,
        forceRefresh: forceRefresh,
        onProgress: onProgress,
      );
      switch (result.status) {
        case DanmakuFetchStatus.fromCache:
        case DanmakuFetchStatus.fromNetwork:
          return _outcomeFrom(result);
        case DanmakuFetchStatus.empty:
          sawEmpty = true;
          break;
        case DanmakuFetchStatus.noMatch:
          sawNoMatch = true;
          break;
        case DanmakuFetchStatus.failed:
          sawFailure = true;
          break;
      }
    }
    if (foundBinding) {
      return DanmakuLoadOutcome._(
        status: sawFailure
            ? DanmakuStatus.failed
            : sawEmpty
            ? DanmakuStatus.empty
            : DanmakuStatus.noMatch,
      );
    }

    for (final source in sources) {
      final result = await repository.loadForVideo(
        sourceId: source.id,
        baseUrl: source.baseUrl,
        request: DanmakuVideoRequest(
          videoIdentity: identity.stableKey,
          fileName: identity.fileName,
          fileHash: identity.fileHash,
          fileSize: identity.fileSize,
          videoKey: identity.stableKey,
        ),
        forceRefresh: forceRefresh,
        onProgress: onProgress,
      );
      if (result.status == DanmakuFetchStatus.noMatch && metadata != null) {
        final scraped = await _loadFromMetadata(
          source,
          identity,
          metadata,
          onProgress,
          forceRefresh: forceRefresh,
        );
        if (scraped != null) {
          switch (scraped.status) {
            case DanmakuStatus.ready:
              return scraped;
            case DanmakuStatus.empty:
              sawEmpty = true;
              break;
            case DanmakuStatus.failed:
              sawFailure = true;
              break;
            case DanmakuStatus.noMatch:
              sawNoMatch = true;
              break;
            case DanmakuStatus.idle:
            case DanmakuStatus.loading:
              break;
          }
          continue;
        }
      }
      switch (result.status) {
        case DanmakuFetchStatus.fromCache:
        case DanmakuFetchStatus.fromNetwork:
          return _outcomeFrom(result);
        case DanmakuFetchStatus.empty:
          sawEmpty = true;
          break;
        case DanmakuFetchStatus.noMatch:
          sawNoMatch = true;
          break;
        case DanmakuFetchStatus.failed:
          sawFailure = true;
          break;
      }
    }
    if (sawFailure) {
      return const DanmakuLoadOutcome._(status: DanmakuStatus.failed);
    }
    if (sawEmpty) {
      return const DanmakuLoadOutcome._(status: DanmakuStatus.empty);
    }
    if (sawNoMatch) {
      return const DanmakuLoadOutcome._(status: DanmakuStatus.noMatch);
    }
    return const DanmakuLoadOutcome._(status: DanmakuStatus.noMatch);
  }

  Future<DanmakuLoadOutcome?> _loadFromMetadata(
    DanmakuSourceConfig source,
    vid.VideoIdentity identity,
    VideoMetadataContext metadata,
    DanmakuProgressCallback onProgress, {
    required bool forceRefresh,
  }) async {
    final episodeNumber = metadata.episodeNumber;
    if (episodeNumber == null || episodeNumber <= 0) return null;
    final titles = <String>[
      metadata.displayTitle,
      if (metadata.originalTitle != null &&
          metadata.originalTitle!.trim().isNotEmpty &&
          metadata.originalTitle != metadata.displayTitle)
        metadata.originalTitle!,
    ];
    for (final title in titles) {
      onProgress(
        DanmakuLoadProgress(
          phase: DanmakuLoadPhase.matching,
          sourceId: source.id,
        ),
      );
      final List<scrape.DanmakuCatalogAnime> catalog;
      try {
        catalog = await scrapeSourceFor(source).searchEpisodes(title);
      } on Exception {
        continue;
      }
      final candidates = [
        for (final anime in catalog)
          for (final episode in anime.episodes)
            if (!isDanmakuPromotionalEpisodeTitle(episode.episodeTitle) &&
                (episode.episodeNumber ??
                        mapper.DanmakuEpisodeParser.parse(
                          episode.episodeTitle,
                        ).episode) ==
                    episodeNumber)
              episode,
      ];
      // A formal title that still maps to several catalog entries is
      // ambiguous (usually multiple seasons). Never choose the first item.
      if (candidates.length != 1) continue;
      try {
        final result = await repository.loadForEpisode(
          sourceId: source.id,
          baseUrl: source.baseUrl,
          request: DanmakuVideoRequest(
            videoIdentity: identity.stableKey,
            fileName: identity.fileName,
            fileHash: identity.fileHash,
            fileSize: identity.fileSize,
            videoKey: identity.stableKey,
          ),
          episodeId: candidates.single.episodeId,
          forceRefresh: forceRefresh,
          onProgress: onProgress,
        );
        return _outcomeFrom(result);
      } on Exception {
        continue;
      }
    }
    return null;
  }

  DanmakuLoadOutcome _outcomeFrom(DanmakuFetchResult result) {
    switch (result.status) {
      case DanmakuFetchStatus.fromCache:
      case DanmakuFetchStatus.fromNetwork:
        return DanmakuLoadOutcome._(
          status: DanmakuStatus.ready,
          items: itemsFromComments(result.entry!.comments),
        );
      case DanmakuFetchStatus.empty:
        return const DanmakuLoadOutcome._(status: DanmakuStatus.empty);
      case DanmakuFetchStatus.noMatch:
        return const DanmakuLoadOutcome._(status: DanmakuStatus.noMatch);
      case DanmakuFetchStatus.failed:
        return const DanmakuLoadOutcome._(status: DanmakuStatus.failed);
    }
  }

  /// Drops the memoized outcome for [identity] (manual re-match).
  void invalidate(vid.VideoIdentity identity) =>
      _inFlight.remove(identity.stableKey);

  /// Source comments -> pipeline models. Protocol mode mapping:
  /// 1/6/7 scroll, 4 bottom, 5 top (source contract), and the pipeline
  /// models' DanmakuType mirrors that.
  static List<models.DanmakuItemModel> itemsFromComments(
    Iterable<DanmakuSourceComment> comments,
  ) {
    final items = <models.DanmakuItemModel>[];
    for (final c in comments) {
      final type = switch (c.mode) {
        4 => models.DanmakuType.bottom,
        5 => models.DanmakuType.top,
        _ => models.DanmakuType.scroll,
      };
      items.add(
        models.DanmakuItemModel(
          time: c.timeSeconds,
          text: c.content,
          type: type,
          color: c.colorRgb & 0xFFFFFF,
          danmakuId: c.danmakuId,
        ),
      );
    }
    return items;
  }

  /// Real scrape adapter for [SeriesScraper]: search + /match over one
  /// configured deployment.
  DanmakuScrapeSource scrapeSourceFor(DanmakuSourceConfig config) =>
      _DanmuApiScrapeSource(config);

  /// Real scrape repository adapter, pinned to the same source configuration
  /// as the search adapter for the lifetime of a batch run.
  DanmakuScrapeRepository scrapeRepositoryFor(DanmakuSourceConfig config) =>
      _ScrapeRepositoryAdapter(this, config);

  DanmakuScrapeRepository get scrapeRepository {
    final config = primarySource;
    if (config == null) {
      throw const scrape.DanmakuScrapeException('未配置弹幕源', retryable: false);
    }
    return scrapeRepositoryFor(config);
  }
}

/// Adapter: [DanmuApiSource] search/match -> [DanmakuScrapeSource].
class _DanmuApiScrapeSource implements DanmakuScrapeSource {
  _DanmuApiScrapeSource(this.config);

  final DanmakuSourceConfig config;

  DanmuApiSource _source() => DanmuApiSource(
    DanmuApiConfig(
      baseUrl: config.baseUrl,
      token: config.token,
      sourceId: config.id,
      displayName: config.name,
    ),
  );

  @override
  Future<List<scrape.DanmakuCatalogAnime>> searchEpisodes(
    String title, {
    DanmakuCancelToken? cancelToken,
  }) async {
    try {
      final groups = await _source()
          .searchEpisodes(anime: title, cancelToken: cancelToken)
          .timeout(const Duration(seconds: 30));
      return groups.map(_toCatalogAnime).toList();
    } on DanmakuSourceException catch (error) {
      throw _toScrapeException(error);
    } on TimeoutException {
      throw const scrape.DanmakuScrapeException('弹幕源请求超时', retryable: true);
    }
  }

  @override
  Future<scrape.DanmakuEpisodeRef?> match(
    VideoIdentity video, {
    DanmakuCancelToken? cancelToken,
  }) async {
    try {
      final m = await _source()
          .match(
            fileName: video.fileName,
            fileHash: video.fileHash,
            fileSize: video.fileSize,
            matchMode: video.fileHash?.isNotEmpty == true
                ? 'hashAndFileName'
                : 'fileName',
            cancelToken: cancelToken,
          )
          .timeout(const Duration(seconds: 30));
      if (m == null) return null;
      return scrape.DanmakuEpisodeRef(
        animeId: m.animeId,
        episodeId: m.episodeId,
        animeTitle: m.animeTitle,
        episodeTitle: m.episodeTitle,
        shift: m.shift,
      );
    } on DanmakuSourceException catch (error) {
      throw _toScrapeException(error);
    } on TimeoutException {
      throw const scrape.DanmakuScrapeException('弹幕源请求超时', retryable: true);
    }
  }

  scrape.DanmakuCatalogAnime _toCatalogAnime(DanmakuSourceEpisodeGroup g) {
    final eps = g.episodes.map((e) {
      final parsed = mapper.DanmakuEpisodeParser.parse(e.episodeTitle);
      return scrape.DanmakuCatalogEpisode(
        episodeId: e.episodeId,
        episodeTitle: e.episodeTitle,
        episodeNumber: parsed.episode,
      );
    }).toList();
    return scrape.DanmakuCatalogAnime(
      animeId: g.animeId,
      animeTitle: g.animeTitle,
      episodes: eps,
    );
  }
}

/// Adapter: [DanmakuRepository] -> [DanmakuScrapeRepository].
class _ScrapeRepositoryAdapter implements DanmakuScrapeRepository {
  _ScrapeRepositoryAdapter(this._service, this._config);

  final DanmakuService _service;
  final DanmakuSourceConfig _config;

  @override
  Future<bool> hasValidCache(
    String videoKey, {
    bool forceRefresh = false,
    String? episodeId,
  }) {
    if (forceRefresh) return Future.value(false);
    return _service.cache
        .read(sourceId: _sourceId, baseUrl: _baseUrl, videoIdentity: videoKey)
        .then(
          (e) => e != null && (episodeId == null || e.episodeId == episodeId),
        );
  }

  @override
  Future<int> fetchAndCache(
    scrape.DanmakuEpisodeRef ref,
    String videoKey, {
    DanmakuCancelToken? cancelToken,
  }) async {
    final result = await _service.repository.loadForEpisode(
      sourceId: _sourceId,
      baseUrl: _baseUrl,
      request: DanmakuVideoRequest(videoIdentity: videoKey, fileName: videoKey),
      episodeId: ref.episodeId,
      shiftSeconds: ref.shift,
      cancelToken: cancelToken,
      forceRefresh: true,
    );
    if (result.status == DanmakuFetchStatus.failed) {
      final error = result.error;
      if (error != null) throw _toScrapeException(error);
      throw const scrape.DanmakuScrapeException('弹幕加载失败');
    }
    return result.entry?.comments.length ?? 0;
  }

  String get _sourceId => _config.id;

  String get _baseUrl => _config.baseUrl;
}

scrape.DanmakuScrapeException _toScrapeException(DanmakuSourceException error) {
  return scrape.DanmakuScrapeException(
    error.message,
    statusCode: switch (error) {
      DanmakuRateLimitException() => 429,
      DanmakuAuthException() => 401,
      DanmakuRequestException() => 400,
      DanmakuServerException() => 500,
      _ => null,
    },
    retryable:
        error is DanmakuNetworkException ||
        error is DanmakuRateLimitException ||
        error is DanmakuServerException,
  );
}

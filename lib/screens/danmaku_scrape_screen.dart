import 'package:flutter/material.dart';

import '../danmaku/scraper/scrape_state.dart';
import '../danmaku/scraper/series_scraper.dart';
import '../danmaku/scraper/video_enumerator.dart';
import '../danmaku/service/danmaku_service.dart';
import '../danmaku/identity/video_identity.dart' as danmaku_identity;
import '../danmaku/model/episode_title_classifier.dart';
import '../services/library_folders.dart';
import 'danmaku_settings_screen.dart';
import '../l10n/app_localizations.dart';

typedef SeriesScraperFactory =
    SeriesScraper Function(
      DanmakuScrapeSource source,
      DanmakuScrapeRepository repository,
      VoidCallback onChanged,
    );

/// Progress surface for scraping every playable episode below one library
/// folder.  The dependencies are injectable to keep the UI deterministic in
/// widget tests while production uses the shared danmaku service.
class DanmakuScrapeScreen extends StatefulWidget {
  const DanmakuScrapeScreen({
    super.key,
    required this.folder,
    required this.seriesTitle,
    this.enumerator,
    this.service,
    this.scraperFactory,
    this.initialVideos = const [],
    this.enumerateFolder = true,
    this.openSeriesPickerOnReady = false,
    this.suggestedEpisode,
    this.matchSingleEpisode = false,
  });

  final LibraryFolder folder;
  final String seriesTitle;
  final DanmakuVideoEnumerator? enumerator;
  final DanmakuService? service;
  final SeriesScraperFactory? scraperFactory;
  final List<ScrapeVideo> initialVideos;

  /// Unified-library callers already have the complete, season-scoped file
  /// list. Disabling enumeration prevents an unrelated rescan of the source
  /// root and keeps other titles out of the task.
  final bool enumerateFolder;

  /// Opens the series picker as soon as preparation completes. Detail pages
  /// use this so tapping “match season” lands directly on the useful choice.
  final bool openSeriesPickerOnReady;

  /// Episode to put at the top of the remote episode picker.
  final int? suggestedEpisode;

  /// Match only the clicked episode (including its source versions).
  final bool matchSingleEpisode;

  @override
  State<DanmakuScrapeScreen> createState() => _DanmakuScrapeScreenState();
}

class _DanmakuScrapeScreenState extends State<DanmakuScrapeScreen> {
  late final DanmakuService _service =
      widget.service ?? DanmakuService.instance;
  late final DanmakuVideoEnumerator _enumerator =
      widget.enumerator ?? DanmakuVideoEnumerator();
  SeriesScraper? _scraper;
  SeriesScope? _scope;
  List<ScrapeVideo> _videos = const [];
  bool _preparing = true;
  bool _disposing = false;
  bool _selecting = false;
  String? _setupError;
  bool _noSource = false;
  bool _didOpenInitialPicker = false;

  SeriesScrapeState? get _state => _scraper?.state;
  bool get _running =>
      _preparing ||
      switch (_state?.phase) {
        ScrapePhase.scanning ||
        ScrapePhase.matching ||
        ScrapePhase.downloading => true,
        _ => false,
      };

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _disposing = true;
    if (_running) _scraper?.cancel();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      await _service.init();
      final config = _service.primarySource;
      if (config == null) {
        if (mounted) {
          setState(() {
            _preparing = false;
            _noSource = true;
          });
        }
        return;
      }
      final found = widget.enumerateFolder
          ? await _enumerator.enumerate(
              VideoSource.fromLibraryFolder(widget.folder),
              folderName: widget.folder.name,
            )
          : const <EnumeratedVideo>[];
      final enumerated = <ScrapeVideo>[];
      for (final video in found) {
        final identity = await danmaku_identity.identityForAsync(video.item);
        enumerated.add(
          ScrapeVideo(
            key: identity.stableKey,
            fileName: identity.fileName,
            fileHash: identity.fileHash,
            sizeBytes: identity.fileSize,
            season: video.episode.season > 0 ? video.episode.season : null,
            episode: video.episode.episode > 0 ? video.episode.episode : null,
          ),
        );
      }
      // The details page already owns the authoritative direct-child listing
      // (notably SAF bookmarks and Jellyfin indices). Merge that with the
      // recursive enumerator and de-duplicate by stable playback identity.
      final byKey = <String, ScrapeVideo>{};
      for (final video in enumerated) {
        byKey.putIfAbsent(video.key, () => video);
      }
      for (final video in widget.initialVideos) {
        final normalized = _withNamespacedKey(video);
        byKey.putIfAbsent(normalized.key, () => normalized);
      }
      final videos = byKey.values.toList()
        ..sort((a, b) {
          final season = (a.season ?? 0).compareTo(b.season ?? 0);
          if (season != 0) return season;
          final episode = (a.episode ?? 1 << 20).compareTo(
            b.episode ?? 1 << 20,
          );
          return episode != 0 ? episode : a.fileName.compareTo(b.fileName);
        });
      final scope = SeriesScope(
        sourceId: config.id,
        sourceBaseUrl: config.baseUrl,
        seriesTitle: widget.seriesTitle.trim().isEmpty
            ? widget.folder.name
            : widget.seriesTitle.trim(),
        seriesKey: widget.folder.metadataKey,
      );
      late final SeriesScraper scraper;
      scraper =
          widget.scraperFactory?.call(
            _service.scrapeSourceFor(config),
            _service.scrapeRepositoryFor(config),
            _changed,
          ) ??
          SeriesScraper(
            source: _service.scrapeSourceFor(config),
            repository: _service.scrapeRepositoryFor(config),
            onChanged: _changed,
          );
      await scraper.restore(scope, videos: videos);
      if (!mounted) return;
      setState(() {
        _videos = videos;
        _scope = scope;
        _scraper = scraper;
        _preparing = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _setupError = 'Could not scan this series: $error';
        });
      }
    }
  }

  ScrapeVideo _withNamespacedKey(ScrapeVideo video) => ScrapeVideo(
    key: video.key.startsWith('danmaku:') ? video.key : 'danmaku:${video.key}',
    fileName: video.fileName,
    fileHash: video.fileHash,
    sizeBytes: video.sizeBytes,
    season: video.season,
    episode: video.episode,
  );

  void _changed() {
    if (!_disposing && mounted) setState(() {});
  }

  Future<List<DanmakuCatalogAnime>?> _loadCandidates() async {
    final scraper = _scraper;
    final scope = _scope;
    if (scraper == null || scope == null || _selecting) return null;
    setState(() => _selecting = true);
    try {
      final candidates = await scraper.searchCandidates(scope);
      if (!mounted || _disposing) return null;
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: AppText('No danmaku series candidates found'),
          ),
        );
        return null;
      }
      return candidates;
    } catch (error) {
      if (mounted && !_disposing) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: AppText('Could not load candidates: $error')),
        );
      }
      return null;
    } finally {
      if (mounted && !_disposing) setState(() => _selecting = false);
    }
  }

  Future<void> _chooseInitialSeries() async {
    if (widget.matchSingleEpisode) {
      final episodes = _state?.episodes;
      if (episodes == null || episodes.isEmpty) return;
      await _chooseEpisode(episodes.first);
    } else {
      await _chooseSeriesForBatch();
    }
  }

  Future<void> _chooseSeriesForBatch() async {
    final candidates = await _loadCandidates();
    if (candidates == null || !mounted) return;
    final selected = await showModalBottomSheet<DanmakuCatalogAnime>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _SeriesCandidateSheet(
        title: widget.seriesTitle,
        candidates: candidates,
      ),
    );
    if (selected == null || !mounted) return;
    // Whole-season scraping always anchors at the first real catalog episode,
    // never at the playback resume episode. Missing local files keep their
    // original episode numbers instead of shifting the rest of the season.
    final numbered =
        selected.episodes
            .where(
              (episode) =>
                  !isDanmakuPromotionalEpisodeTitle(episode.episodeTitle) &&
                  episode.episodeNumber != null &&
                  episode.episodeNumber! > 0,
            )
            .toList()
          ..sort((a, b) => a.episodeNumber!.compareTo(b.episodeNumber!));
    if (numbered.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: AppText('Remote episode has no index')),
      );
      return;
    }
    final offset = numbered.first.episodeNumber! - 1;
    final bound = await _scraper?.bindSeries(
      _scope!,
      _videos,
      selected,
      episodeOffset: offset,
    );
    if (mounted && !_disposing) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: AppText(
            'Saved ${bound ?? 0} / ${_videos.length} episode bindings',
          ),
        ),
      );
    }
    _changed();
    if (mounted && !_disposing) await _run();
  }

  Future<void> _chooseEpisode(ScrapeEpisodeState episode) async {
    final candidates = await _loadCandidates();
    if (candidates == null || !mounted) return;
    final episodeNumber = episode.episode;
    final anime = await showModalBottomSheet<DanmakuCatalogAnime>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _SeriesCandidateSheet(
        title: widget.seriesTitle,
        candidates: candidates,
      ),
    );
    if (anime == null || !mounted) return;
    final selected = await showModalBottomSheet<_EpisodeCandidate>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _EpisodeCandidateSheet(
        title: 'Select exact danmaku episode',
        localLabel: episodeNumber == null
            ? episode.fileName
            : 'Episode $episodeNumber',
        anime: anime,
        suggestedEpisode: episodeNumber,
      ),
    );
    if (selected == null || !mounted) return;
    final ref = DanmakuEpisodeRef(
      animeId: selected.anime.animeId,
      episodeId: selected.episode.episodeId,
      animeTitle: selected.anime.animeTitle,
      episodeTitle: selected.episode.episodeTitle,
    );
    final keys = widget.matchSingleEpisode
        ? _videos.map((video) => video.key)
        : [episode.key];
    for (final key in keys) {
      if (!mounted || _disposing) return;
      await _scraper?.manualMatchEpisode(_scope!, key, ref);
    }
    _changed();
  }

  Future<void> _run({bool force = false}) async {
    final scraper = _scraper;
    final scope = _scope;
    if (scraper == null || scope == null || _videos.isEmpty) return;
    setState(() {});
    await scraper.start(scope, _videos, forceRefresh: force);
    _changed();
  }

  Future<void> _retryFailed() async {
    final scraper = _scraper;
    final scope = _scope;
    if (scraper == null || scope == null) return;
    await scraper.retryFailed(scope);
    _changed();
  }

  Future<void> _configureSource() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DanmakuSettingsScreen(service: _service),
      ),
    );
    if (!mounted || _service.primarySource == null) return;
    setState(() {
      _preparing = true;
      _noSource = false;
      _setupError = null;
    });
    await _prepare();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.openSeriesPickerOnReady &&
        !_didOpenInitialPicker &&
        !_preparing &&
        !_noSource &&
        _setupError == null &&
        _videos.isNotEmpty) {
      _didOpenInitialPicker = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted && !_disposing) await _chooseInitialSeries();
      });
    }
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: AppText(
          widget.matchSingleEpisode
              ? 'Match current episode danmaku'
              : 'Scrape series danmaku',
        ),
      ),
      body: SafeArea(
        child: _preparing
            ? const Center(child: CircularProgressIndicator())
            : _noSource
            ? _NoSource(onConfigure: _configureSource)
            : _setupError != null
            ? _Message(icon: Icons.error_outline, text: _setupError!)
            : _videos.isEmpty
            ? const _Message(
                icon: Icons.video_library_outlined,
                text: 'No playable episodes were found in this folder.',
              )
            : _content(theme),
      ),
    );
  }

  Widget _content(ThemeData theme) {
    final state = _state;
    final finished =
        state?.episodes
            .where(
              (e) =>
                  e.status.isTerminal ||
                  e.status == ScrapeStatus.matched ||
                  e.status == ScrapeStatus.cancelled,
            )
            .length ??
        0;
    final total = state?.total ?? _videos.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppText(
                    widget.seriesTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: total == 0 ? 0 : finished / total,
                  ),
                  const SizedBox(height: 8),
                  AppText('$finished / $total · ${_phaseLabel(state?.phase)}'),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_running)
                        OutlinedButton.icon(
                          key: const Key('cancel-scrape'),
                          onPressed: _scraper?.cancel,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const AppText('Cancel'),
                        ),
                      if (!_running &&
                          ((state?.failedCount ?? 0) > 0 ||
                              (state?.noMatchCount ?? 0) > 0))
                        FilledButton.tonalIcon(
                          key: const Key('retry-failed'),
                          onPressed: _retryFailed,
                          icon: const Icon(Icons.refresh),
                          label: const AppText('Retry failed'),
                        ),
                      if (!_running)
                        FilledButton.tonalIcon(
                          key: const Key('select-danmaku-series'),
                          onPressed: _selecting ? null : _chooseInitialSeries,
                          icon: _selecting
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.playlist_add_check_circle_outlined,
                                ),
                          label: AppText(
                            widget.matchSingleEpisode
                                ? 'Match current episode danmaku'
                                : 'Select series and batch match',
                          ),
                        ),
                      if (!_running)
                        OutlinedButton.icon(
                          key: const Key('precache-season'),
                          onPressed: () => _run(),
                          icon: const Icon(Icons.cloud_download_outlined),
                          label: AppText(
                            widget.matchSingleEpisode
                                ? 'Pre-cache current episode'
                                : 'Pre-cache whole season',
                          ),
                        ),
                    ],
                  ),
                  if ((state?.noMatchCount ?? 0) > 0) ...[
                    const SizedBox(height: 12),
                    AppText(
                      'Unmatched or duplicate candidates need manual matching. '
                      'Select a remote series for batch matching, or tap an episode to change its source.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: state?.episodes.length ?? _videos.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final episode = state?.episodes.elementAt(index);
              final video = _videos[index];
              return _EpisodeTile(
                fileName: episode?.fileName ?? video.fileName,
                season: episode?.season ?? video.season,
                episode: episode?.episode ?? video.episode,
                status: episode?.status ?? ScrapeStatus.pending,
                commentCount: episode?.commentCount,
                error: episode?.error,
                ref: episode?.ref,
                onTap: episode == null || _running
                    ? null
                    : () => _chooseEpisode(episode),
              );
            },
          ),
        ),
      ],
    );
  }

  static String _phaseLabel(ScrapePhase? phase) => switch (phase) {
    ScrapePhase.scanning => 'Scanning',
    ScrapePhase.matching => 'Matching',
    ScrapePhase.downloading => 'Downloading',
    ScrapePhase.completed => 'Completed',
    ScrapePhase.cancelled => 'Cancelled',
    ScrapePhase.partialFailure => 'Partially completed',
    ScrapePhase.failed => 'Failed',
    _ => 'Ready',
  };
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.fileName,
    required this.status,
    this.season,
    this.episode,
    this.commentCount,
    this.error,
    this.ref,
    this.onTap,
  });
  final String fileName;
  final ScrapeStatus status;
  final int? season;
  final int? episode;
  final int? commentCount;
  final String? error;
  final DanmakuEpisodeRef? ref;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = season != null && episode != null
        ? 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
        : fileName;
    return Card(
      child: ListTile(
        onTap: onTap,
        dense: true,
        leading: Icon(_statusIcon(status), color: _statusColor(theme, status)),
        title: AppText(label),
        subtitle: AppText(
          error ??
              (ref?.episodeTitle == null
                  ? (label == fileName ? '' : fileName)
                  : '弹幕：${ref!.episodeTitle}'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Semantics(
          label: 'Status ${status.name}',
          child: Chip(label: AppText(_statusLabel(status, commentCount))),
        ),
      ),
    );
  }

  static String _statusLabel(ScrapeStatus status, int? count) =>
      switch (status) {
        ScrapeStatus.cached => 'cached',
        ScrapeStatus.success => 'success${count == null ? '' : ' · $count'}',
        ScrapeStatus.empty => 'empty',
        ScrapeStatus.noMatch => 'noMatch',
        ScrapeStatus.failed => 'failed',
        ScrapeStatus.cancelled => 'cancelled',
        ScrapeStatus.matched => 'matched',
        ScrapeStatus.fetching => 'fetching',
        ScrapeStatus.pending => 'pending',
      };

  static IconData _statusIcon(ScrapeStatus status) => switch (status) {
    ScrapeStatus.cached => Icons.inventory_2_outlined,
    ScrapeStatus.success => Icons.check_circle_outline,
    ScrapeStatus.empty => Icons.comments_disabled_outlined,
    ScrapeStatus.noMatch => Icons.link_off,
    ScrapeStatus.failed => Icons.error_outline,
    ScrapeStatus.cancelled => Icons.cancel_outlined,
    _ => Icons.downloading_outlined,
  };

  static Color _statusColor(ThemeData theme, ScrapeStatus status) =>
      status == ScrapeStatus.failed || status == ScrapeStatus.noMatch
      ? theme.colorScheme.error
      : status == ScrapeStatus.success ||
            status == ScrapeStatus.cached ||
            status == ScrapeStatus.matched
      ? theme.colorScheme.primary
      : theme.colorScheme.onSurfaceVariant;
}

class _NoSource extends StatelessWidget {
  const _NoSource({required this.onConfigure});
  final VoidCallback onConfigure;
  @override
  Widget build(BuildContext context) => _Message(
    icon: Icons.settings_outlined,
    text:
        'No danmaku source is enabled. Add and enable one in Settings → Danmaku sources, then try again.',
    action: OutlinedButton.icon(
      key: const Key('configure-source'),
      onPressed: onConfigure,
      icon: const Icon(Icons.settings_outlined),
      label: const AppText('Configure source'),
    ),
  );
}

class _SeriesCandidateSheet extends StatelessWidget {
  const _SeriesCandidateSheet({required this.title, required this.candidates});
  final String title;
  final List<DanmakuCatalogAnime> candidates;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: AppText(
              'Select danmaku series · $title',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: candidates.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final candidate = candidates[index];
                final episodeCount = candidate.episodes
                    .where(
                      (episode) => !isDanmakuPromotionalEpisodeTitle(
                        episode.episodeTitle,
                      ),
                    )
                    .length;
                return ListTile(
                  key: Key('series-candidate-${candidate.animeId}'),
                  leading: const Icon(Icons.live_tv_outlined),
                  title: AppText(candidate.animeTitle),
                  subtitle: AppText('$episodeCount episodes'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, candidate),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class _EpisodeCandidate {
  const _EpisodeCandidate({required this.anime, required this.episode});
  final DanmakuCatalogAnime anime;
  final DanmakuCatalogEpisode episode;
}

class _EpisodeCandidateSheet extends StatefulWidget {
  const _EpisodeCandidateSheet({
    required this.title,
    required this.localLabel,
    required this.anime,
    this.suggestedEpisode,
  });
  final String title;
  final String localLabel;
  final DanmakuCatalogAnime anime;
  final int? suggestedEpisode;

  @override
  State<_EpisodeCandidateSheet> createState() => _EpisodeCandidateSheetState();
}

class _EpisodeCandidateSheetState extends State<_EpisodeCandidateSheet> {
  String _query = '';

  List<DanmakuCatalogEpisode> get _episodes {
    final normalized = _query.trim().toLowerCase();
    final items = widget.anime.episodes.where((episode) {
      if (isDanmakuPromotionalEpisodeTitle(episode.episodeTitle)) return false;
      if (normalized.isEmpty) return true;
      return episode.episodeTitle.toLowerCase().contains(normalized) ||
          '${episode.episodeNumber ?? ''}' == normalized;
    }).toList();
    final suggested = widget.suggestedEpisode;
    if (normalized.isEmpty && suggested != null) {
      items.sort((a, b) {
        final aDistance = ((a.episodeNumber ?? 1 << 20) - suggested).abs();
        final bDistance = ((b.episodeNumber ?? 1 << 20) - suggested).abs();
        return aDistance.compareTo(bDistance);
      });
    }
    return items;
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppText(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                AppText(
                  '${widget.localLabel} · ${widget.anime.animeTitle}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search episode number or title',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: _episodes.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final episode = _episodes[index];
                return ListTile(
                  key: Key('episode-candidate-${episode.episodeId}'),
                  leading: const Icon(Icons.subtitles_outlined),
                  title: AppText(episode.episodeTitle),
                  subtitle: episode.episodeNumber == null
                      ? null
                      : AppText('Remote episode ${episode.episodeNumber}'),
                  onTap: () => Navigator.pop(
                    context,
                    _EpisodeCandidate(anime: widget.anime, episode: episode),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            AppText(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    ),
  );
}

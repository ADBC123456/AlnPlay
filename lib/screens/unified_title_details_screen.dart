import '../widgets/cached_image.dart';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../danmaku/binding/danmaku_binding_store.dart';
import '../danmaku/scraper/scrape_state.dart';
import '../danmaku/service/danmaku_service.dart';
import '../library/models/library_models.dart';
import '../library/episode_target.dart';
import '../library/title_playback_preferences.dart';
import '../library/unified_library_service.dart';
import '../l10n/app_localizations.dart';
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/library_folders.dart';
import '../services/watched_store.dart';
import '../theme/app_theme.dart';
import '../widgets/episode_picker_sheet.dart';
import 'danmaku_scrape_screen.dart';
import 'player_screen.dart';

/// Aggregated title page. Homepage posters always land here; source browsing
/// remains a separate workflow on the library screen.
class UnifiedTitleDetailsScreen extends StatefulWidget {
  const UnifiedTitleDetailsScreen({super.key, required this.titleId});

  final String titleId;

  @override
  State<UnifiedTitleDetailsScreen> createState() =>
      _UnifiedTitleDetailsScreenState();
}

class _UnifiedTitleDetailsScreenState extends State<UnifiedTitleDetailsScreen> {
  Color get _pageColor => Theme.of(context).scaffoldBackgroundColor;

  final UnifiedLibraryService _library = UnifiedLibraryService.instance;
  final ScrollController _pageController = ScrollController();
  List<ContinueWatchingEntry> _progress = [];
  int? _selectedSeason;
  bool _seasonChosen = false;
  bool _progressLoaded = false;
  int _progressRequest = 0;
  int _focusRevision = 0;
  EpisodeTarget? _target;
  TitlePlaybackPreference? _preference;
  Set<String> _watched = const {};
  bool _opening = false;
  bool _refreshing = false;
  bool _overviewExpanded = false;
  Map<String, ScrapeEpisodeState> _danmakuByFileKey = const {};
  String? _requestedDanmakuScope;
  double _heroHeight = 0;
  bool _pastHero = false;

  ContinueWatchingEntry? get _resume =>
      _target?.progress ??
      (_library.snapshot.titles[widget.titleId]?.kind == MediaTitleKind.movie
          ? _progress.firstOrNull
          : null);

  @override
  void initState() {
    super.initState();
    _library.addListener(_onLibraryChanged);
    ContinueWatchingStore.changes.addListener(_loadProgress);
    _pageController.addListener(_onPageScrolled);
    _loadProgress();
  }

  @override
  void dispose() {
    _library.removeListener(_onLibraryChanged);
    ContinueWatchingStore.changes.removeListener(_loadProgress);
    _pageController.removeListener(_onPageScrolled);
    _pageController.dispose();
    super.dispose();
  }

  void _onPageScrolled() {
    final pastHero =
        _pageController.offset >= (_heroHeight - 72).clamp(0, double.infinity);
    if (pastHero != _pastHero && mounted) setState(() => _pastHero = pastHero);
  }

  void _onLibraryChanged() {
    if (mounted) {
      setState(() {
        _target = resolveEpisodeTarget(
          snapshot: _library.snapshot,
          titleId: widget.titleId,
          progress: _progress,
          preference: _preference,
          watchedKeys: _watched,
        );
      });
    }
  }

  Future<void> _loadProgress({bool focus = false}) async {
    final request = ++_progressRequest;
    final entries = await ContinueWatchingStore.load();
    final preference = await TitlePlaybackPreferences.load(widget.titleId);
    final watched = await WatchedStore.load();
    if (!mounted || request != _progressRequest) return;
    final keys = _library.snapshot
        .filesForTitle(widget.titleId)
        .map((file) => file.legacyResumeKey)
        .toSet();
    setState(() {
      _progress =
          entries
              .where(
                (entry) =>
                    entry.video.metadataContext?.titleId == widget.titleId ||
                    keys.contains(ContinueWatchingStore.keyFor(entry.video)),
              )
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _preference = preference;
      _watched = watched;
      _target = resolveEpisodeTarget(
        snapshot: _library.snapshot,
        titleId: widget.titleId,
        progress: _progress,
        preference: preference,
        watchedKeys: watched,
      );
      if (!_progressLoaded || focus) {
        _selectedSeason = _target?.episode.seasonNumber;
        _seasonChosen = _target != null;
        _focusRevision++;
      }
      _progressLoaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _library.snapshot;
    final title = snapshot.titles[widget.titleId];
    if (title == null) {
      return Scaffold(
        backgroundColor: _pageColor,
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: Center(child: AppText('影片信息不可用')),
      );
    }

    final files = snapshot
        .filesForTitle(title.id)
        .where((f) => f.availability != MediaAvailability.missing)
        .toList();
    final episodes =
        snapshot.episodes.values.where((e) => e.titleId == title.id).toList()
          ..sort(_compareEpisodes);
    final List<int?> seasons =
        episodes.map((e) => e.seasonNumber).whereType<int>().toSet().toList()
          ..sort();
    if (episodes.any((episode) => episode.seasonNumber == null)) {
      seasons.add(null);
    }
    if (_progressLoaded && !_seasonChosen && seasons.isNotEmpty) {
      _seasonChosen = true;
      _selectedSeason = seasons.firstWhere(
        (s) => s != null && s > 0,
        orElse: () => seasons.first,
      );
    }
    if (_selectedSeason != null && !seasons.contains(_selectedSeason)) {
      _selectedSeason = seasons.firstOrNull;
    }
    final visibleEpisodes = episodes
        .where((e) => e.seasonNumber == _selectedSeason)
        .toList();
    final danmakuScope = '${title.id}:s${_selectedSeason ?? 'unknown'}';
    if (_requestedDanmakuScope != danmakuScope) {
      _requestedDanmakuScope = danmakuScope;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _loadDanmakuMatches(title, _selectedSeason),
      );
    }
    final duplicates = episodes
        .where((e) => snapshot.versionsForEpisode(e.id).length > 1)
        .toList();

    final media = MediaQuery.of(context);
    final contentInsets = EdgeInsets.only(
      left: media.viewPadding.left > 24 ? media.viewPadding.left : 24,
      right: media.viewPadding.right > 24 ? media.viewPadding.right : 24,
    );
    final textScale = media.textScaler.scale(14) / 14;
    final heroHeight =
        (media.size.width >= 900
            ? (media.size.height * .56).clamp(380.0, 520.0)
            : (media.size.height * .62).clamp(440.0, 610.0)) +
        (textScale - 1).clamp(0.0, 2.0) * 130;
    _heroHeight = heroHeight;

    final pageOverlay = _pastHero
        ? AppTheme.systemOverlayStyle(Theme.of(context).brightness)
        : SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
          );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: pageOverlay,
      child: Scaffold(
        backgroundColor: _pageColor,
        body: CustomScrollView(
          controller: _pageController,
          slivers: [
            SliverAppBar(
              pinned: true,
              automaticallyImplyLeading: false,
              expandedHeight: heroHeight - media.padding.top,
              backgroundColor: _pageColor,
              surfaceTintColor: Colors.transparent,
              leading: _pastHero ? const BackButton() : null,
              title: _pastHero
                  ? Text(
                      title.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              flexibleSpace: FlexibleSpaceBar(
                collapseMode: CollapseMode.pin,
                background: SizedBox(
                  height: heroHeight,
                  child: _TitleHero(
                    contentInsets: contentInsets,
                    title: title,
                    ownedEpisodes: episodes.length,
                    playLabel: _primaryLabel(),
                    opening: _opening,
                    refreshing: _refreshing,
                    canPlay: _progressLoaded && files.isNotEmpty,
                    onBack: () => Navigator.maybePop(context),
                    onPlay: () => _playPrimary(title, episodes, files),
                    onPlayMpv: Platform.isAndroid
                        ? () => _playPrimary(
                            title,
                            episodes,
                            files,
                            engine: PlayEngine.mpv,
                          )
                        : null,
                    onMenu: (value) =>
                        _handleMenu(value, title, files, visibleEpisodes),
                  ),
                ),
              ),
            ),
            if (title.overview.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: contentInsets.copyWith(bottom: 18),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () =>
                        setState(() => _overviewExpanded = !_overviewExpanded),
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 5),
                      child: AppText(
                        title.overview,
                        maxLines: _overviewExpanded ? null : 3,
                        overflow: _overviewExpanded
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 14,
                          height: 1.55,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (title.kind == MediaTitleKind.tv) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: contentInsets,
                  child: _SeasonHeader(
                    seasons: seasons,
                    selected: _selectedSeason,
                    onSelected: (season) {
                      _requestedDanmakuScope = null;
                      setState(() => _selectedSeason = season);
                    },
                    onEpisodes: () =>
                        _openEpisodePicker(title, visibleEpisodes),
                    onDanmaku: visibleEpisodes.isEmpty
                        ? null
                        : () => _openDanmaku(
                            title,
                            _selectedSeason,
                            visibleEpisodes,
                            suggestedEpisode: _suggestedDanmakuEpisode(
                              visibleEpisodes,
                            ),
                          ),
                  ),
                ),
              ),
              if (!_progressLoaded)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 210,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else if (visibleEpisodes.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: contentInsets.copyWith(top: 20, bottom: 32),
                    child: AppText(
                      '这一季暂时没有可播放的剧集',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else
                SliverToBoxAdapter(
                  child: Padding(
                    padding: contentInsets,
                    child: _EpisodeRail(
                      key: ValueKey(_selectedSeason),
                      targetEpisodeId: _target?.episode.id,
                      focusRevision: _focusRevision,
                      episodes: visibleEpisodes,
                      versionsFor: snapshot.versionsForEpisode,
                      progressFor: _episodeProgress,
                      danmakuFor: _episodeDanmaku,
                      onPlay: (episode, versions) =>
                          _chooseAndPlay(title, episode, versions),
                      onMore: (episode, versions) =>
                          _showEpisodeActions(title, episode, versions),
                    ),
                  ),
                ),
              if (duplicates.isNotEmpty)
                SliverToBoxAdapter(
                  child: _DuplicateNotice(
                    count: duplicates.length,
                    onTap: () => _showDuplicates(title, duplicates),
                  ),
                ),
            ] else
              SliverPadding(
                padding: contentInsets.copyWith(top: 8),
                sliver: SliverList.builder(
                  itemCount: files.length,
                  itemBuilder: (_, index) => ListTile(
                    minTileHeight: 62,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.movie_outlined),
                    title: AppText(files[index].originalFileName),
                    subtitle: AppText(
                      '${_sourceLabel(files[index])} · ${_sizeLabel(files[index].sizeBytes)}',
                    ),
                    trailing: Icon(Icons.play_arrow_rounded),
                    onTap: () => _playVersion(title, null, files[index]),
                  ),
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: 42)),
          ],
        ),
      ),
    );
  }

  static int _compareEpisodes(LibraryEpisode a, LibraryEpisode b) {
    final season = (a.seasonNumber ?? 1 << 20).compareTo(
      b.seasonNumber ?? 1 << 20,
    );
    return season == 0 ? a.episodeNumber.compareTo(b.episodeNumber) : season;
  }

  _EpisodeProgress? _episodeProgress(List<MediaFile> versions) {
    for (final file in versions) {
      final entry = _progress
          .where(
            (e) =>
                ContinueWatchingStore.keyFor(e.video) == file.legacyResumeKey,
          )
          .firstOrNull;
      if (entry == null) continue;
      final duration = entry.video.duration;
      return _EpisodeProgress(
        entry.position,
        duration > Duration.zero
            ? (entry.position.inMilliseconds / duration.inMilliseconds).clamp(
                0.0,
                1.0,
              )
            : null,
      );
    }
    return null;
  }

  ScrapeEpisodeState? _episodeDanmaku(List<MediaFile> versions) {
    for (final file in versions) {
      final key = file.legacyResumeKey;
      final state = _danmakuByFileKey[key] ?? _danmakuByFileKey['danmaku:$key'];
      if (state?.ref != null &&
          (state!.status == ScrapeStatus.matched ||
              state.status == ScrapeStatus.success ||
              state.status == ScrapeStatus.empty ||
              state.status == ScrapeStatus.cached)) {
        return state;
      }
    }
    return null;
  }

  Future<void> _loadDanmakuMatches(MediaTitle title, int? season) async {
    final service = DanmakuService.instance;
    await service.init();
    final source = service.primarySource;
    if (source == null || !mounted) return;
    final folder = LibraryFolder(
      id: 'unified:${title.id}:s${season ?? 'unknown'}',
      name: title.displayTitle,
      path: 'unified:${title.id}',
      addedAt: DateTime.now(),
    );
    final scope = SeriesScope(
      sourceId: source.id,
      sourceBaseUrl: source.baseUrl,
      seriesTitle: title.displayTitle,
      seriesKey: folder.metadataKey,
    );
    final bindings = await DanmakuBindingStore.loadForScope(scope);
    if (!mounted ||
        _requestedDanmakuScope != '${title.id}:s${season ?? 'unknown'}') {
      return;
    }
    setState(() {
      _danmakuByFileKey = {
        for (final entry in bindings.entries)
          entry.key: ScrapeEpisodeState(
            key: entry.key,
            fileName: entry.key,
            status: ScrapeStatus.matched,
            ref: entry.value.ref,
          ),
      };
    });
  }

  String _primaryLabel() {
    final entry = _resume;
    if (entry == null) {
      return _target == null ? '播放' : '播放第 ${_target!.episode.episodeNumber} 集';
    }
    final episode = entry.video.metadataContext?.episodeNumber;
    return episode == null
        ? '继续播放  ${_clock(entry.position)}'
        : '播放第 $episode 集  ${_clock(entry.position)}';
  }

  Future<void> _handleMenu(
    String value,
    MediaTitle title,
    List<MediaFile> files,
    List<LibraryEpisode> episodes,
  ) async {
    if (value == 'refresh') {
      await _refreshTitle(files);
      return;
    }
    if (value == 'danmaku') {
      await _openDanmaku(
        title,
        _selectedSeason,
        episodes,
        suggestedEpisode: _suggestedDanmakuEpisode(episodes),
      );
      return;
    }
    if (value == 'copy') {
      await Clipboard.setData(ClipboardData(text: title.displayTitle));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: AppText('片名已复制')));
      }
    }
  }

  Future<void> _refreshTitle(List<MediaFile> files) async {
    if (_refreshing) return;
    final rootIds = files.expand((file) => file.rootIds).toSet();
    final folders = (await LibraryFoldersStore.load())
        .where((folder) => rootIds.contains(folder.id))
        .toList();
    if (!mounted) return;
    if (folders.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText('没有找到可刷新的来源目录')));
      return;
    }
    setState(() => _refreshing = true);
    try {
      await _library.refresh(folders);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: AppText('刮削信息已刷新')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: AppText('刷新失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _playPrimary(
    MediaTitle title,
    List<LibraryEpisode> episodes,
    List<MediaFile> files, {
    PlayEngine engine = PlayEngine.media3,
  }) async {
    if (title.kind == MediaTitleKind.movie) {
      await _chooseAndPlay(title, null, files, engine: engine);
      return;
    }
    final target = _target;
    if (target == null) return;
    if (target.progress != null || target.replay) {
      await _playVersion(
        title,
        target.episode,
        target.file,
        engine: engine,
        startFromBeginning: target.replay,
      );
      return;
    }
    await _chooseAndPlay(
      title,
      target.episode,
      _library.snapshot.versionsForEpisode(target.episode.id),
      engine: engine,
    );
  }

  Future<void> _chooseAndPlay(
    MediaTitle title,
    LibraryEpisode? episode,
    List<MediaFile> versions, {
    PlayEngine engine = PlayEngine.media3,
  }) async {
    if (versions.isEmpty) return;
    if (versions.length == 1) {
      await _playVersion(title, episode, versions.single, engine: engine);
      return;
    }
    final preference = await TitlePlaybackPreferences.load(title.id);
    final preferred = versions
        .where((f) => f.sourceRef.sourceId == preference?.preferredSourceId)
        .toList();
    if (preferred.length == 1) {
      await _playVersion(title, episode, preferred.single, engine: engine);
      return;
    }
    if (!mounted) return;
    final selected = await showModalBottomSheet<_VersionChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      builder: (_) => _VersionSheet(episode: episode, versions: versions),
    );
    if (selected == null) return;
    if (selected.remember) {
      await TitlePlaybackPreferences.save(
        titleId: title.id,
        preferredSourceId: selected.file.sourceRef.sourceId,
      );
    }
    await _playVersion(title, episode, selected.file, engine: engine);
  }

  Future<void> _openEpisodePicker(
    MediaTitle title,
    List<LibraryEpisode> episodes,
  ) async {
    final selected = await showModalBottomSheet<LibraryEpisode>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(maxWidth: 820),
      builder: (_) => EpisodePickerSheet(
        episodes: episodes,
        season: _selectedSeason,
        currentEpisodeId: _target?.episode.id,
        // The model's total is title-wide, not a per-season count.
        total:
            _library.snapshot.episodes.values
                    .where((episode) => episode.titleId == title.id)
                    .map((episode) => episode.seasonNumber)
                    .toSet()
                    .length ==
                1
            ? title.totalEpisodeCount
            : null,
        isAvailable: (episode) =>
            _library.snapshot.versionsForEpisode(episode.id).isNotEmpty,
        positionFor: (episode) => _episodeProgress(
          _library.snapshot.versionsForEpisode(episode.id),
        )?.position,
      ),
    );
    if (selected == null || !mounted) return;
    final versions = _library.snapshot.versionsForEpisode(selected.id);
    if (versions.isEmpty) return;
    setState(() {
      _target = EpisodeTarget(
        selected,
        versions.first,
        progress: _progress
            .where(
              (entry) =>
                  ContinueWatchingStore.keyFor(entry.video) ==
                  versions.first.legacyResumeKey,
            )
            .firstOrNull,
      );
      _selectedSeason = selected.seasonNumber;
      _focusRevision++;
    });
    await _chooseAndPlay(title, selected, versions);
  }

  Future<void> _playVersion(
    MediaTitle title,
    LibraryEpisode? episode,
    MediaFile file, {
    PlayEngine engine = PlayEngine.media3,
    bool startFromBeginning = false,
  }) async {
    setState(() => _opening = true);
    try {
      final resolved = await _library.resolvePlayable(file);
      final video = resolved.withMetadataContext(
        VideoMetadataContext(
          titleId: title.id,
          displayTitle: title.displayTitle,
          originalTitle: title.originalTitle,
          seasonNumber: episode?.seasonNumber,
          episodeNumber: episode?.episodeNumber,
          episodeTitle: episode?.displayName,
          revision: title.revision,
        ),
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            video: video,
            initialEngine: engine,
            startFromBeginning: startFromBeginning,
          ),
        ),
      );
      await _loadProgress(focus: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: AppText('无法打开这个版本：$error')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _showEpisodeActions(
    MediaTitle title,
    LibraryEpisode episode,
    List<MediaFile> versions,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: AppText(
                '第 ${episode.episodeNumber} 集 · ${episode.displayName}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              minTileHeight: 56,
              leading: Icon(Icons.play_arrow_rounded),
              title: AppText(versions.length > 1 ? '选择播放版本' : '播放本集'),
              onTap: () => Navigator.pop(context, 'play'),
            ),
            ListTile(
              minTileHeight: 56,
              leading: Icon(Icons.subtitles_outlined),
              title: AppText('匹配本集弹幕'),
              onTap: () => Navigator.pop(context, 'danmaku'),
            ),
          ],
        ),
      ),
    );
    if (action == 'play') {
      await _chooseAndPlay(title, episode, versions);
    } else if (action == 'danmaku') {
      await _openDanmaku(
        title,
        episode.seasonNumber,
        [episode],
        suggestedEpisode: episode.episodeNumber,
        matchSingleEpisode: true,
      );
    }
  }

  Future<void> _showDuplicates(
    MediaTitle title,
    List<LibraryEpisode> episodes,
  ) async {
    final selected = await showModalBottomSheet<LibraryEpisode>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(20, 6, 20, 8),
                child: AppText(
                  '重复剧集版本',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: AppText(
                  '同一集只显示一张卡片，所有来源版本都保留。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final episode in episodes)
                      ListTile(
                        minTileHeight: 58,
                        title: AppText(
                          '第 ${episode.episodeNumber} 集 · ${episode.displayName}',
                        ),
                        subtitle: AppText(
                          '${_library.snapshot.versionsForEpisode(episode.id).length} 个版本',
                        ),
                        trailing: Icon(Icons.chevron_right),
                        onTap: () => Navigator.pop(context, episode),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      await _chooseAndPlay(
        title,
        selected,
        _library.snapshot.versionsForEpisode(selected.id),
      );
    }
  }

  Future<void> _openDanmaku(
    MediaTitle title,
    int? season,
    List<LibraryEpisode> episodes, {
    int? suggestedEpisode,
    bool matchSingleEpisode = false,
  }) async {
    final videos = <ScrapeVideo>[];
    for (final episode in episodes) {
      for (final file in _library.snapshot.versionsForEpisode(episode.id)) {
        videos.add(
          ScrapeVideo(
            key: file.legacyResumeKey,
            fileName: file.originalFileName,
            sizeBytes: file.sizeBytes,
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
          ),
        );
      }
    }
    if (videos.isEmpty || !mounted) return;
    final folder = LibraryFolder(
      id: 'unified:${title.id}:s${season ?? 'unknown'}',
      name: title.displayTitle,
      path: 'unified:${title.id}',
      addedAt: DateTime.now(),
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DanmakuScrapeScreen(
          folder: folder,
          seriesTitle: title.displayTitle,
          initialVideos: videos,
          enumerateFolder: false,
          openSeriesPickerOnReady: true,
          suggestedEpisode: suggestedEpisode,
          matchSingleEpisode: matchSingleEpisode,
        ),
      ),
    );
    _requestedDanmakuScope = '${title.id}:s${season ?? 'unknown'}';
    await _loadDanmakuMatches(title, season);
  }

  int? _suggestedDanmakuEpisode(List<LibraryEpisode> episodes) {
    final resumed = _resume?.video.metadataContext?.episodeNumber;
    if (resumed != null &&
        episodes.any((episode) => episode.episodeNumber == resumed)) {
      return resumed;
    }
    return episodes.firstOrNull?.episodeNumber;
  }
}

class _TitleHero extends StatelessWidget {
  const _TitleHero({
    required this.contentInsets,
    required this.title,
    required this.ownedEpisodes,
    required this.playLabel,
    required this.opening,
    required this.refreshing,
    required this.canPlay,
    required this.onBack,
    required this.onPlay,
    required this.onPlayMpv,
    required this.onMenu,
  });

  final MediaTitle title;
  final EdgeInsets contentInsets;
  final int ownedEpisodes;
  final String playLabel;
  final bool opening;
  final bool refreshing;
  final bool canPlay;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback? onPlayMpv;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: Color(0xFF171820)),
        _Artwork(primary: title.backdrop, fallback: title.poster),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, .30, .64, 1],
              colors: [
                Color(0x28000000),
                Color(0x08000000),
                Theme.of(
                  context,
                ).scaffoldBackgroundColor.withValues(alpha: .94),
                Theme.of(context).scaffoldBackgroundColor,
              ],
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          left: false,
          right: false,
          child: Padding(
            padding: contentInsets.copyWith(top: 10, bottom: 0),
            child: Align(
              alignment: Alignment.topCenter,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _CircleButton(
                    tooltip: '返回',
                    icon: Icons.arrow_back_ios_new_rounded,
                    onPressed: onBack,
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多操作',
                    onSelected: onMenu,
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'refresh',
                        child: _MenuRow(Icons.refresh, '刷新刮削信息'),
                      ),
                      if (title.kind == MediaTitleKind.tv)
                        PopupMenuItem(
                          value: 'danmaku',
                          child: _MenuRow(Icons.subtitles_outlined, '匹配当前季弹幕'),
                        ),
                      PopupMenuItem(
                        value: 'copy',
                        child: _MenuRow(Icons.copy_outlined, '复制片名'),
                      ),
                    ],
                    child: _CircleSurface(loading: refreshing),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: wide ? 24 : 18,
          child: Padding(
            padding: contentInsets,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppText(
                  title.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: wide ? 34 : 28,
                    height: 1.08,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.4,
                  ),
                ),
                SizedBox(height: 17),
                if (wide && MediaQuery.textScalerOf(context).scale(14) <= 18)
                  Row(
                    children: [
                      Flexible(
                        child: _PlayButton(
                          label: playLabel,
                          loading: opening,
                          enabled: canPlay,
                          onTap: onPlay,
                        ),
                      ),
                      if (onPlayMpv != null) ...[
                        SizedBox(width: 10),
                        _MpvButton(
                          enabled: canPlay && !opening,
                          onTap: onPlayMpv!,
                        ),
                      ],
                      SizedBox(width: 20),
                      Expanded(
                        child: _Metadata(title: title, owned: ownedEpisodes),
                      ),
                    ],
                  )
                else ...[
                  _Metadata(title: title, owned: ownedEpisodes),
                  SizedBox(height: 13),
                  Row(
                    children: [
                      Expanded(
                        child: _PlayButton(
                          label: playLabel,
                          loading: opening,
                          enabled: canPlay,
                          onTap: onPlay,
                        ),
                      ),
                      if (onPlayMpv != null) ...[
                        SizedBox(width: 10),
                        _MpvButton(
                          enabled: canPlay && !opening,
                          onTap: onPlayMpv!,
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({this.primary, this.fallback});
  final String? primary;
  final String? fallback;

  @override
  Widget build(BuildContext context) {
    final url = primary ?? fallback;
    if (url == null) {
      return Center(
        child: Icon(Icons.movie_outlined, size: 72, color: Colors.white24),
      );
    }
    return CachedImage(
      url,
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => fallback != null && fallback != url
          ? CachedImage(
              fallback!,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => SizedBox.shrink(),
            )
          : SizedBox.shrink(),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: .24),
    shape: CircleBorder(side: BorderSide(color: Colors.white38)),
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      color: Colors.white,
    ),
  );
}

class _CircleSurface extends StatelessWidget {
  const _CircleSurface({required this.loading});
  final bool loading;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: .24),
    shape: CircleBorder(side: BorderSide(color: Colors.white38)),
    child: SizedBox.square(
      dimension: 48,
      child: Center(
        child: loading
            ? SizedBox.square(
                dimension: 19,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(Icons.more_horiz_rounded, color: Colors.white),
      ),
    ),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) =>
      Row(children: [Icon(icon), SizedBox(width: 12), AppText(label)]);
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.label,
    required this.loading,
    required this.enabled,
    required this.onTap,
  });
  final String label;
  final bool loading;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    style: FilledButton.styleFrom(
      minimumSize: Size(0, 54),
      padding: EdgeInsets.symmetric(horizontal: 22),
      backgroundColor: Theme.of(context).colorScheme.onSurface,
      foregroundColor: Theme.of(context).colorScheme.surface,
      disabledBackgroundColor: Theme.of(
        context,
      ).colorScheme.surfaceContainerHigh,
      disabledForegroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
    ),
    onPressed: enabled && !loading ? onTap : null,
    icon: loading
        ? SizedBox.square(
            dimension: 19,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(Icons.play_arrow_rounded, size: 27),
    label: AppText(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
}

class _MpvButton extends StatelessWidget {
  const _MpvButton({required this.enabled, required this.onTap});
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton.outlined(
    tooltip: '使用 MPV 播放',
    onPressed: enabled ? onTap : null,
    style: IconButton.styleFrom(
      minimumSize: Size(54, 54),
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      side: BorderSide(color: Theme.of(context).colorScheme.outline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    icon: Icon(Icons.smart_display_outlined),
  );
}

class _Metadata extends StatelessWidget {
  const _Metadata({required this.title, required this.owned});
  final MediaTitle title;
  final int owned;

  @override
  Widget build(BuildContext context) {
    final facts = <String>[
      if (title.rating > 0) 'TMDB ${title.rating.toStringAsFixed(1)}',
      if (title.releaseDate?.isNotEmpty == true)
        title.releaseDate!
      else if (title.year != null)
        '${title.year}',
      if (title.kind == MediaTitleKind.tv)
        title.totalEpisodeCount == null
            ? '库中 $owned 集'
            : '共 ${title.totalEpisodeCount} 集 · 库中 $owned 集'
      else
        '电影',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var i = 0; i < facts.length; i++) ...[
              if (i > 0)
                Text(
                  '·',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              AppText(
                facts[i],
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
        if (title.genres.isNotEmpty) ...[
          SizedBox(height: 7),
          AppText(
            title.genres.take(4).join('  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        ],
      ],
    );
  }
}

class _SeasonHeader extends StatelessWidget {
  const _SeasonHeader({
    required this.seasons,
    required this.selected,
    required this.onSelected,
    required this.onDanmaku,
    required this.onEpisodes,
  });
  final List<int?> seasons;
  final int? selected;
  final ValueChanged<int?> onSelected;
  final VoidCallback? onDanmaku;
  final VoidCallback onEpisodes;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(0, 4, 0, 7),
    child: Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final season in seasons)
                  _SeasonTab(
                    label: season == null
                        ? '未知季'
                        : season == 0
                        ? '特别篇'
                        : '第 $season 季',
                    selected: season == selected,
                    onTap: () => onSelected(season),
                  ),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: '选集',
          onPressed: onEpisodes,
          icon: Icon(Icons.grid_view_rounded),
        ),
        IconButton(
          tooltip: '匹配当前季弹幕',
          onPressed: onDanmaku,
          icon: Icon(Icons.subtitles_outlined),
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ],
    ),
  );
}

class _SeasonTab extends StatelessWidget {
  const _SeasonTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(4),
    child: Padding(
      padding: EdgeInsets.fromLTRB(13, 10, 13, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppText(
            label,
            style: TextStyle(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 18,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          SizedBox(height: 7),
          AnimatedContainer(
            duration: Duration(milliseconds: 130),
            width: selected ? 48 : 0,
            height: 3,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.onSurface,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    ),
  );
}

class _EpisodeProgress {
  const _EpisodeProgress(this.position, this.fraction);
  final Duration position;
  final double? fraction;
}

class _EpisodeRail extends StatefulWidget {
  const _EpisodeRail({
    super.key,
    required this.targetEpisodeId,
    required this.focusRevision,
    required this.episodes,
    required this.versionsFor,
    required this.progressFor,
    required this.danmakuFor,
    required this.onPlay,
    required this.onMore,
  });
  final List<LibraryEpisode> episodes;
  final String? targetEpisodeId;
  final int focusRevision;
  final List<MediaFile> Function(String) versionsFor;
  final _EpisodeProgress? Function(List<MediaFile>) progressFor;
  final ScrapeEpisodeState? Function(List<MediaFile>) danmakuFor;
  final void Function(LibraryEpisode, List<MediaFile>) onPlay;
  final void Function(LibraryEpisode, List<MediaFile>) onMore;

  @override
  State<_EpisodeRail> createState() => _EpisodeRailState();
}

class _EpisodeRailState extends State<_EpisodeRail> {
  ScrollController? _controller;
  double? _viewport;
  bool _focusPending = false;

  @override
  void didUpdateWidget(covariant _EpisodeRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Background metadata/danmaku refreshes must not steal a manual scroll.
    if (oldWidget.focusRevision != widget.focusRevision) _focusPending = true;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = constraints.maxWidth;
      final width = viewport >= 900
          ? 254.0
          : viewport >= 600
          ? 224.0
          : 174.0;
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final index = widget.episodes.indexWhere(
        (episode) => episode.id == widget.targetEpisodeId,
      );
      final leadingPadding = (viewport - width) / 2;
      final offset = (index < 0 ? 0 : index) * (width + 14);
      if (_controller == null) {
        // Start at the target before first paint: no flash of episode 1.
        _controller = ScrollController(initialScrollOffset: offset);
      } else if (_focusPending || _viewport != viewport) {
        _focusPending = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_controller?.hasClients != true) return;
          _controller!.jumpTo(
            offset.clamp(0.0, _controller!.position.maxScrollExtent),
          );
        });
      }
      _viewport = viewport;
      return SizedBox(
        height: width * 9 / 16 + 48 + 68 * scale,
        child: ListView.separated(
          controller: _controller,
          padding: EdgeInsets.fromLTRB(leadingPadding, 0, leadingPadding, 8),
          scrollDirection: Axis.horizontal,
          itemCount: widget.episodes.length,
          separatorBuilder: (_, _) => SizedBox(width: 14),
          itemBuilder: (_, index) {
            final episode = widget.episodes[index];
            final versions = widget.versionsFor(episode.id);
            return SizedBox(
              key: ValueKey('rail-${episode.id}'),
              width: width,
              child: _EpisodeCard(
                episode: episode,
                versions: versions,
                progress: widget.progressFor(versions),
                danmaku: widget.danmakuFor(versions),
                onPlay: () => widget.onPlay(episode, versions),
                onMore: () => widget.onMore(episode, versions),
              ),
            );
          },
        ),
      );
    },
  );
}

class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    required this.episode,
    required this.versions,
    required this.progress,
    required this.danmaku,
    required this.onPlay,
    required this.onMore,
  });
  final LibraryEpisode episode;
  final List<MediaFile> versions;
  final _EpisodeProgress? progress;
  final ScrapeEpisodeState? danmaku;
  final VoidCallback onPlay;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AspectRatio(
        aspectRatio: 16 / 9,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: versions.isEmpty ? null : onPlay,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (episode.still != null)
                  CachedImage(
                    episode.still!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => SizedBox.shrink(),
                  )
                else
                  Center(
                    child: Icon(
                      Icons.movie_outlined,
                      color: Colors.white24,
                      size: 36,
                    ),
                  ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0x8C000000)],
                    ),
                  ),
                ),
                Center(
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 34,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
                  ),
                ),
                if (episode.runtime != null)
                  Positioned(
                    right: 8,
                    bottom: 7,
                    child: AppText(
                      _clock(episode.runtime!),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(color: Colors.black, blurRadius: 5)],
                      ),
                    ),
                  ),
                if (progress?.fraction != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                      value: progress!.fraction,
                      minHeight: 3,
                      color: Color(0xFF3F8CFF),
                      backgroundColor: Colors.white24,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      SizedBox(height: 7),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AppText(
              '${episode.episodeNumber}. ${episode.displayName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            width: 48,
            height: 40,
            child: IconButton(
              padding: EdgeInsets.zero,
              alignment: Alignment.topRight,
              tooltip: '剧集操作',
              onPressed: onMore,
              icon: Icon(Icons.more_horiz, size: 21),
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      if (versions.isEmpty)
        AppText(
          '不可用',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        )
      else if (versions.length > 1)
        AppText(
          '${versions.length} 个版本',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        )
      else if (progress != null)
        AppText(
          '看到 ${_clock(progress!.position)}',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      if (danmaku?.ref != null)
        Tooltip(
          message: danmaku!.ref!.animeTitle ?? '',
          child: AppText(
            '弹幕：${danmaku!.ref!.episodeTitle ?? '第 ${episode.episodeNumber} 集'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Color(0xFF7CB5FF), fontSize: 12),
          ),
        ),
    ],
  );
}

class _DuplicateNotice extends StatelessWidget {
  const _DuplicateNotice({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(24, 10, 24, 0),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                Icons.copy_all_outlined,
                size: 19,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              SizedBox(width: 10),
              Expanded(child: AppText('检测到 $count 集存在重复版本未展开显示')),

              SizedBox(width: 3),
              Icon(
                Icons.chevron_right,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _VersionChoice {
  const _VersionChoice(this.file, this.remember);
  final MediaFile file;
  final bool remember;
}

class _VersionSheet extends StatefulWidget {
  const _VersionSheet({required this.episode, required this.versions});
  final LibraryEpisode? episode;
  final List<MediaFile> versions;

  @override
  State<_VersionSheet> createState() => _VersionSheetState();
}

class _VersionSheetState extends State<_VersionSheet> {
  late MediaFile _selected = widget.versions.first;
  bool _remember = true;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText(
            widget.episode == null
                ? '选择播放版本'
                : '第 ${widget.episode!.episodeNumber} 集 · 选择播放版本',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 10),
          for (final file in widget.versions)
            RadioListTile<MediaFile>(
              value: file,
              // ignore: deprecated_member_use
              groupValue: _selected,
              // ignore: deprecated_member_use
              onChanged: (value) {
                if (value != null) setState(() => _selected = value);
              },
              contentPadding: EdgeInsets.zero,
              title: AppText(_sourceLabel(file)),
              subtitle: AppText(
                '${file.originalFileName} · ${_sizeLabel(file.sizeBytes)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          CheckboxListTile(
            value: _remember,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: (value) => setState(() => _remember = value ?? false),
            title: AppText('此剧优先使用该来源'),
          ),
          SizedBox(height: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: Size(0, 52)),
            onPressed: () =>
                Navigator.pop(context, _VersionChoice(_selected, _remember)),
            icon: Icon(Icons.play_arrow_rounded),
            label: AppText('播放'),
          ),
        ],
      ),
    ),
  );
}

String _clock(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

String _sourceLabel(MediaFile file) => switch (file.sourceRef.sourceType) {
  'webdav' => 'WebDAV',
  'jellyfin' => 'Jellyfin',
  'smb' => 'SMB',
  'ftp' => 'FTP / SFTP',
  'upnp' => 'DLNA',
  _ => Platform.isIOS ? 'Files' : '本地存储',
};

String _sizeLabel(int? bytes) {
  if (bytes == null || bytes <= 0) return '大小未知';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

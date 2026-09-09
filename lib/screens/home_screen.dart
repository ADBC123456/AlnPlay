import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app.dart' show appRouteObserver;
import '../library/models/library_models.dart';
import '../library/repository/library_repository.dart';
import '../library/scanner/library_scanner.dart';
import '../library/unified_library_service.dart';
import '../library/widgets/scan_depth_setting.dart';
import '../models/video_item.dart';
import '../services/continue_watching.dart';
import '../services/file_browser.dart';
import '../services/ftp_client.dart';
import '../services/jellyfin_client.dart';
import '../services/library_folders.dart';
import '../services/smb_client.dart';
import '../services/strm_playback.dart';
import '../services/tmdb_client.dart';
import '../services/webdav_client.dart';
import '../widgets/library_home_cards.dart';
import '../services/recent_library_items.dart';
import '../widgets/tv_text_field.dart';
import 'ftp_screen.dart';
import 'player_screen.dart';
import '../widgets/tv_overscan.dart';
import 'file_browser_screen.dart';
import 'jellyfin_screen.dart';
import '../utils/file_info_extractor.dart';
import '../utils/startup_permissions.dart';
import 'smb_screen.dart';
import 'folder_screen.dart';
import 'upnp_screen.dart';
import 'unified_title_details_screen.dart';
import 'webdav_screen.dart';
import '../l10n/app_localizations.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.refreshTick,
    this.searchActive = false,
    this.onSearchDismissed,
    this.sourcesOnly = false,
  });

  final bool sourcesOnly;

  /// Notifies the screen that it became visible again (e.g. the Library tab
  /// was re-selected) so it can reload its continue-watching list.
  final Listenable? refreshTick;

  /// Controlled by the root Dock. Search stays a contextual library action
  /// instead of becoming a fourth navigation destination.
  final bool searchActive;

  /// Closes the contextual search and lets the root restore the tab that was
  /// visible before search opened.
  final VoidCallback? onSearchDismissed;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, RouteAware {
  final TextEditingController _librarySearchController =
      TextEditingController();
  Timer? _librarySearchDebounce;
  String _librarySearch = '';
  bool _sortByName = false;
  bool _refreshing = false;
  bool _openingRecent = false;
  bool _keyboardWasVisible = false;

  /// "Continue watching": videos with a saved resume position, most recently
  /// played first (persisted via [ContinueWatchingStore]).
  List<ContinueWatchingEntry> _entries = const [];

  /// "Your library": the folders the user added (e.g. TV-show folders), most
  /// recently added first. Nothing is auto-scanned — only these appear.
  List<LibraryFolder> _folders = const [];
  List<_SavedSource> _savedSources = const [];

  /// Cached server-side metadata for the [JellyfinItemInfo] folders, keyed by
  /// `LibraryFolder.id` (fetch-on-bookmark, refreshed on open).
  Map<String, JellyfinItemInfo> _jellyfinMeta = const {};

  final JellyfinClient _client = JellyfinClient();
  final UnifiedLibraryService _unifiedLibrary = UnifiedLibraryService.instance;

  /// Scrolls the home list back to the top after returning from playback, so
  /// the app-bar title and "Continue watching" heading are visible again.
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.refreshTick?.addListener(_loadLibrary);
    // Reload whenever the persisted list changes (e.g. a save or remove).
    ContinueWatchingStore.changes.addListener(_loadLibrary);
    LibraryFoldersStore.changes.addListener(_loadLibrary);
    // Update cards when TMDB metadata resolves for a visible entry.
    TmdService.instance.addListener(_onMetadataChanged);
    _unifiedLibrary.addListener(_onUnifiedLibraryChanged);
    unawaited(_unifiedLibrary.initialize());
    _loadLibrary();
    // Ask for every runtime permission at app open instead of mid-playback.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(requestStartupPermissions(context));
    });
  }

  void _onMetadataChanged() {
    if (mounted) setState(() {});
  }

  void _onUnifiedLibraryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    widget.refreshTick?.removeListener(_loadLibrary);
    ContinueWatchingStore.changes.removeListener(_loadLibrary);
    LibraryFoldersStore.changes.removeListener(_loadLibrary);
    TmdService.instance.removeListener(_onMetadataChanged);
    _unifiedLibrary.removeListener(_onUnifiedLibraryChanged);
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _librarySearchDebounce?.cancel();
    _librarySearchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick) {
      oldWidget.refreshTick?.removeListener(_loadLibrary);
      widget.refreshTick?.addListener(_loadLibrary);
    }
    if (oldWidget.searchActive && !widget.searchActive) {
      _librarySearchDebounce?.cancel();
      _librarySearchController.clear();
      _librarySearch = '';
    }
    if (!oldWidget.searchActive && widget.searchActive) {
      _keyboardWasVisible = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.searchActive) return;
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
  }

  /// A route pushed above Home popped (file browser, player, "Open with"), so
  /// resume positions may have changed — refresh the continue-watching list.
  @override
  void didPopNext() {
    _loadLibrary();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The list may have changed while the app was in the background (e.g. the
    // player paused and saved a resume position), so refresh on return.
    if (state == AppLifecycleState.resumed) {
      _loadLibrary();
    }
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final keyboardVisible = View.of(context).viewInsets.bottom > 0;
    if (widget.searchActive && _keyboardWasVisible && !keyboardVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.searchActive) widget.onSearchDismissed?.call();
      });
    }
    _keyboardWasVisible = keyboardVisible;
  }

  Future<void> _loadLibrary() async {
    final entries = await ContinueWatchingStore.load();
    await _loadLibraryFolders();
    if (mounted) {
      setState(() => _entries = entries);
    }
    _resolveMetadata(entries);
  }

  /// Loads the "Your library" folder list, then kicks off best-effort TMDB
  /// lookups so each folder card can show the show's poster.
  Future<void> _loadLibraryFolders() async {
    final folders = await LibraryFoldersStore.load();
    if (mounted) {
      setState(() => _folders = folders);
    }
    unawaited(_loadSavedSources(folders));
    final metas = await _client.loadAllFolderMeta();
    if (mounted) setState(() => _jellyfinMeta = metas);
    _refreshJellyfinMeta(folders);
  }

  Future<void> _loadSavedSources(List<LibraryFolder> folders) async {
    final sources = <_SavedSource>[
      for (final folder in folders.where(
        (folder) => folder.source == LibraryFolderSource.files,
      ))
        _SavedSource(
          id: 'files:${folder.id}',
          kind: _SavedSourceKind.files,
          name: folder.name,
          subtitle: folder.path,
          icon: Icons.folder_rounded,
          folder: folder,
        ),
    ];
    void publish() {
      if (mounted) setState(() => _savedSources = List.of(sources));
    }

    publish();
    try {
      for (final server in await WebDavClient.instance.listServers()) {
        sources.add(
          _SavedSource(
            id: 'webdav:${server.id}',
            kind: _SavedSourceKind.webdav,
            name: server.name,
            subtitle: server.url,
            icon: Icons.cloud_rounded,
            serverId: server.id,
          ),
        );
      }
      publish();
    } catch (_) {}
    try {
      for (final server in await SmbClient.instance.listServers()) {
        sources.add(
          _SavedSource(
            id: 'smb:${server.id}',
            kind: _SavedSourceKind.smb,
            name: server.name,
            subtitle: 'SMB · ${server.host}:${server.port}',
            icon: Icons.lan_rounded,
            serverId: server.id,
          ),
        );
      }
      publish();
    } catch (_) {}
    try {
      for (final server in await FtpClient.instance.listServers()) {
        sources.add(
          _SavedSource(
            id: 'ftp:${server.id}',
            kind: _SavedSourceKind.ftp,
            name: server.name,
            subtitle:
                '${server.protocolLabel} · ${server.host}:${server.port}${server.path}',
            icon: Icons.cloud_queue_rounded,
            serverId: server.id,
          ),
        );
      }
      publish();
    } catch (_) {}
    try {
      for (final server in await _client.loadServers()) {
        sources.add(
          _SavedSource(
            id: 'jellyfin:${server.url}',
            kind: _SavedSourceKind.jellyfin,
            name: server.name,
            subtitle: 'Jellyfin / Emby · ${server.url}',
            icon: Icons.dns_rounded,
            serverId: server.url,
          ),
        );
      }
      publish();
    } catch (_) {}
  }

  /// Best-effort server-side metadata for the Jellyfin library folders: any
  /// folder with no cached entry gets its info fetched from the server (the
  /// bookmark flow already saves it, so this only fills gaps).
  Future<void> _refreshJellyfinMeta(List<LibraryFolder> folders) async {
    for (final folder in folders) {
      if (!folder.isJellyfin || _jellyfinMeta.containsKey(folder.id)) continue;
      final itemId = folder.jellyfinItemId;
      if (itemId == null || itemId.isEmpty) continue;
      try {
        final server = await _client.serverForUrl(
          folder.jellyfinServerUrl ?? '',
        );
        if (server == null || !server.isAuthenticated) continue;
        final info = await _client.getPrimaryPosterInfo(server, itemId);
        if (info == null) continue;
        await _client.saveFolderMeta(folder.id, info);
        if (mounted) {
          setState(() {
            _jellyfinMeta = {..._jellyfinMeta, folder.id: info};
          });
        }
      } catch (_) {
        // Best-effort — the card falls back to the folder name / TMDB lookup.
      }
    }
  }

  Future<void> _resolveFolderMetadata(List<LibraryFolder> folders) async {
    final service = TmdService.instance;
    await service.ensureLoaded();
    for (final folder in folders) {
      final key = folder.metadataKey;
      if (service.metaFor(key) == null) {
        try {
          await service.resolveFolder(key, folder.name);
        } catch (_) {
          // Network failures are non-fatal; the card stays a placeholder.
          continue;
        }
      }
      // Pull the full details (backdrop/overview/cast) right away so the
      // folder's details screen is complete the moment it's opened — metadata
      // is fetched when the folder is added, not when it's opened.
      try {
        await service.detailsFor(key);
      } catch (_) {}
    }
  }

  /// Presents the system folder picker and adds the picked folder to the
  /// library. The folder becomes a card on home only — it is stored under its
  /// own library bookmark, so it never shows up as an Internal-storage root;
  /// its videos stay in place.
  Future<void> _addFolderToLibrary() async {
    final FileEntry? picked;
    try {
      picked = await FileBrowserService.instance.pickLibraryFolder().timeout(
        const Duration(seconds: 60),
      );
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: AppText('The folder picker timed out. Please try again.'),
        ),
      );
      return;
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: AppText(e.message ?? 'Could not pick a folder')),
      );
      return;
    }
    if (picked == null || !mounted) return;
    final maxScanDepth = await _chooseScanDepth(
      LibraryRoot.defaultMaxScanDepth,
    );
    if (maxScanDepth == null || !mounted) return;
    final folder = LibraryFolder(
      id:
          picked.bookmarkId ??
          'folder_${DateTime.now().millisecondsSinceEpoch}',
      name: picked.name,
      path: picked.path,
      addedAt: DateTime.now(),
      maxScanDepth: maxScanDepth,
    );
    await LibraryFoldersStore.add(folder);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: AppText('"${picked.name}" added to your library')),
    );
    // TMDB poster for the new card resolves in the background.
    _resolveFolderMetadata([folder]);
  }

  Future<int?> _chooseScanDepth(int initial) async {
    var selected = initial;
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const AppText('Library scan settings'),
          content: ScanDepthSetting(
            value: selected,
            onChanged: (value) => setDialogState(() => selected = value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const AppText('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selected),
              child: const AppText('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _manageFolder(LibraryFolder folder) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.account_tree_outlined),
              title: const AppText('Scan depth'),
              subtitle: AppText('${folder.maxScanDepth} folder levels'),
              onTap: () => Navigator.pop(sheetContext, 'depth'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const AppText('Remove from library'),
              onTap: () => Navigator.pop(sheetContext, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'remove') {
      await _removeFolder(folder);
    } else if (action == 'depth') {
      final depth = await _chooseScanDepth(folder.maxScanDepth);
      if (depth == null || depth == folder.maxScanDepth) return;
      await LibraryFoldersStore.setMaxScanDepth(folder.id, depth);
      await _loadLibrary();
      final changed = _folders.where((item) => item.id == folder.id).toList();
      if (changed.isNotEmpty) await _unifiedLibrary.refresh(changed);
    }
  }

  Future<void> _removeFolder(LibraryFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('Remove from library?'),
        content: AppText(
          '"${folder.name}" will no longer appear here. '
          'The files stay on your device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const AppText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const AppText('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await LibraryFoldersStore.remove(folder.id);
    // Release the native library bookmark so its grant doesn't linger (only
    // for on-device folders — network/Jellyfin bookmarks have no native grant).
    if (folder.source == LibraryFolderSource.files) {
      try {
        await FileBrowserService.instance.removeLibraryBookmark(folder.id);
      } catch (_) {}
    } else if (folder.isJellyfin) {
      // Drop the cached server-side metadata too so a re-add re-fetches fresh.
      try {
        await _client.removeFolderMeta(folder.id);
      } catch (_) {}
    }
    // Drop the folder's TMDB metadata too so a re-add re-matches cleanly.
    try {
      await TmdService.instance.clear(folder.metadataKey);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _folders = _folders.where((f) => f.id != folder.id).toList();
    });
  }

  /// Best-effort TMDB lookups so cards can show poster art and real titles
  /// without waiting for a tap.
  Future<void> _resolveMetadata(List<ContinueWatchingEntry> entries) async {
    final service = TmdService.instance;
    await service.ensureLoaded();
    for (final e in entries) {
      final video = e.video;
      if (video.metadataContext != null) continue;
      final key = TmdStore.identityKeyFor(video);
      if (service.metaFor(key) != null) continue;
      try {
        await service.resolve(video);
      } catch (_) {
        // Network failures are non-fatal; the card just stays a placeholder.
      }
    }
  }

  Future<void> _removeVideo(ContinueWatchingEntry entry) async {
    final video = entry.video;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const AppText('Remove from Continue watching?'),
        content: AppText('"${video.title}" will no longer appear here.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const AppText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const AppText('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final key = ContinueWatchingStore.keyFor(video);
    await ContinueWatchingStore.remove(key);
    if (!mounted) return;
    setState(() {
      _entries = _entries
          .where((e) => ContinueWatchingStore.keyFor(e.video) != key)
          .toList();
    });
  }

  Future<void> _playRecent(RecentLibraryItem item) async {
    if (_openingRecent) return;
    setState(() => _openingRecent = true);
    try {
      var video = item.entry.video;
      if (item.file != null) {
        video = (await _unifiedLibrary.resolvePlayable(
          item.file!,
        )).withMetadataContext(item.metadata);
      } else {
        final wasTransient = video.uriIsTransient;
        video = (await refreshStrmPlayback(
          video,
        )).withMetadataContext(item.metadata);
        if (video.path != null) {
          await FileBrowserService.instance.resolvePath(video.path!);
        }
        if (!wasTransient) video = await _restoreWebDavSource(video);
        video = (await _restoreJellyfinSource(
          video,
        )).withMetadataContext(item.metadata);
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PlayerScreen(video: video)),
      );
      await _loadLibrary();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: AppText(
              'Could not open video. Check the source and try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _openingRecent = false);
    }
  }

  /// WebDAV entries deliberately do NOT persist the Authorization header (no
  /// plaintext credentials). The saved key encodes the server id + path, so
  /// rebuild the source with a freshly-fetched header and the server's current
  /// URL when the user taps a continue-watching card.
  Future<VideoItem> _restoreWebDavSource(VideoItem video) async {
    final key = video.resumeKey;
    if (key == null || !key.startsWith('webdav_')) return video;
    final rest = key.substring('webdav_'.length);
    // Server id = leading UUID (or legacy integer id), the rest is the path.
    final id =
        RegExp(
          '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',
        ).firstMatch(rest)?.group(0) ??
        RegExp(r'^\d+').firstMatch(rest)?.group(0);
    if (id == null || rest.length <= id.length) return video;
    try {
      final servers = await WebDavClient.instance.listServers();
      WebDavServer? server;
      for (final s in servers) {
        if (s.id == id) {
          server = s;
          break;
        }
      }
      if (server == null) return video;
      var auth = '';
      try {
        auth = await WebDavClient.instance.authorizationHeader(id);
      } on PlatformException {
        auth = '';
      }
      final path = rest.substring(id.length);
      final base = server.url.replaceAll(RegExp(r'/+$'), '');
      return VideoItem(
        id: video.id,
        title: video.title,
        uri: '$base${_encodePath(path)}',
        resumeKey: key,
        duration: video.duration,
        sizeBytes: video.sizeBytes,
        httpHeaders: auth.isEmpty ? const {} : {'Authorization': auth},
        allowSelfSigned: server.allowSelfSigned,
        videoCodec: video.videoCodec,
        audioCodec: video.audioCodec,
        audioChannels: video.audioChannels,
        resolution: video.resolution,
        hdrHint: video.hdrHint,
      );
    } on PlatformException {
      return video;
    }
  }

  /// Jellyfin stream URLs embed the session's `api_key`, which rotates on
  /// re-login. Rebuild the URL from the stable resume key
  /// (`jellyfin:<host>/<item>`) against the current saved server + token.
  Future<VideoItem> _restoreJellyfinSource(VideoItem video) async {
    final key = video.resumeKey;
    if (key == null || !key.startsWith('jellyfin:')) return video;
    final rest = key.substring('jellyfin:'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return video;
    final host = rest.substring(0, slash);
    final itemId = rest.substring(slash + 1);
    if (host.isEmpty || itemId.isEmpty) return video;
    final servers = await _client.loadServers();
    JellyfinServer? server;
    for (final s in servers) {
      if (s.urlHost == host) {
        server = s;
        break;
      }
    }
    if (server == null || !server.isAuthenticated) return video;
    final item = JellyfinItem(id: itemId, name: video.title);
    // Refresh stale api_key in persisted external subtitle URLs (token rotates).
    final refreshedSubs = video.externalSubtitles.map((s) {
      var u = s.uri;
      if (u.contains('api_key=')) {
        u = u.replaceAll(
          RegExp(r'api_key=[^&]*'),
          'api_key=${server!.token ?? ''}',
        );
      }
      return VideoExternalSub(
        uri: u,
        label: s.label,
        language: s.language,
        mimeType: s.mimeType,
        isDefault: s.isDefault,
      );
    }).toList();
    return VideoItem(
      id: video.id,
      title: video.title,
      uri: _client.streamUrl(server, item),
      resumeKey: key,
      duration: video.duration,
      sizeBytes: video.sizeBytes,
      allowSelfSigned: server.allowSelfSigned,
      jellyfinServerId: server.urlHost,
      jellyfinItemId: itemId,
      externalSubtitles: refreshedSubs,
      videoCodec: video.videoCodec,
      audioCodec: video.audioCodec,
      audioChannels: video.audioChannels,
      resolution: video.resolution,
      hdrHint: video.hdrHint,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = _unifiedLibrary.snapshot;
    final newest = <String, int>{};
    for (final file in snapshot.files.values) {
      final id = file.titleId;
      if (id == null) continue;
      final stamp = file.discoveredAt?.millisecondsSinceEpoch ?? 0;
      if (stamp > (newest[id] ?? 0)) newest[id] = stamp;
    }
    final titles =
        snapshot.titles.values
            .where(
              (title) => _matchesLibrarySearch(snapshot, title, _librarySearch),
            )
            .toList()
          ..sort(
            (a, b) => _sortByName
                ? a.displayTitle.toLowerCase().compareTo(
                    b.displayTitle.toLowerCase(),
                  )
                : (newest[b.id] ?? 0).compareTo(newest[a.id] ?? 0),
          );
    final recent = recentLibraryItems(
      _entries,
      snapshot,
      legacyMetadata: (video) =>
          TmdService.instance.metaFor(TmdStore.identityKeyFor(video)),
    );
    final activeScans = _unifiedLibrary.progressByRoot.values
        .where(
          (p) => p.state == ScanState.queued || p.state == ScanState.scanning,
        )
        .toList();
    final incompleteScans = _unifiedLibrary.progressByRoot.values
        .where(
          (p) => p.state == ScanState.failed || p.state == ScanState.partial,
        )
        .toList();
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      // The root search field floats over this screen. Let the keyboard cover
      // the lower shelves instead of relaying out the whole library.
      resizeToAvoidBottomInset: false,
      body: TvOverscan(
        child: Stack(
          children: [
            CustomScrollView(
              key: PageStorageKey(
                widget.sourcesOnly ? 'sources-home' : 'media-home',
              ),
              controller: _scrollController,
              slivers: [
                SliverAppBar(
                  pinned: true,
                  titleSpacing: 16,
                  title: widget.sourcesOnly
                      ? Text(
                          context.tr('Source library'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : Row(
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: SvgPicture.asset(
                                  'assets/alnplay_logo.svg',
                                  width: 30,
                                  height: 30,
                                  excludeFromSemantics: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'AlnPlay',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                  actions: [
                    if (widget.sourcesOnly)
                      IconButton(
                        tooltip: context.tr('Add a source'),
                        onPressed: _showAddMenu,
                        icon: const Icon(Icons.add_rounded),
                      ),
                    if (!widget.sourcesOnly)
                      PopupMenuButton<bool>(
                        tooltip: context.tr('Sort'),
                        icon: const Icon(Icons.sort),
                        initialValue: _sortByName,
                        onSelected: (value) =>
                            setState(() => _sortByName = value),
                        itemBuilder: (_) => [
                          CheckedPopupMenuItem(
                            value: false,
                            checked: !_sortByName,
                            child: AppText('Recently added'),
                          ),
                          CheckedPopupMenuItem(
                            value: true,
                            checked: _sortByName,
                            child: AppText('Title'),
                          ),
                        ],
                      ),
                    IconButton(
                      tooltip: context.tr('Refresh'),
                      onPressed: _refreshing || activeScans.isNotEmpty
                          ? null
                          : widget.sourcesOnly
                          ? _refreshSources
                          : _refreshHome,
                      icon: _refreshing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (widget.searchActive && !widget.sourcesOnly)
                  const SliverToBoxAdapter(child: SizedBox(height: 82)),
                if (!widget.sourcesOnly &&
                    (activeScans.isNotEmpty || _openingRecent))
                  SliverToBoxAdapter(
                    child: LinearProgressIndicator(
                      semanticsLabel: 'Scanning library',
                      minHeight: 3,
                    ),
                  ),
                if (!widget.sourcesOnly && activeScans.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: AppText(
                              '正在扫描 · 已发现 ${activeScans.fold<int>(0, (sum, item) => sum + item.discoveredFiles)} 个文件',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              for (final progress in activeScans) {
                                _unifiedLibrary.cancel(progress.rootId);
                              }
                            },
                            child: const AppText('取消'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!widget.sourcesOnly && incompleteScans.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Material(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                        child: ListTile(
                          leading: const Icon(Icons.sync_problem),
                          title: AppText('${incompleteScans.length} 个来源扫描未完成'),
                          subtitle: const AppText('旧索引已保留，可单独重试失败来源'),
                          trailing: TextButton(
                            onPressed: () => _retryFailedScans(incompleteScans),
                            child: const AppText('重试'),
                          ),
                        ),
                      ),
                    ),
                  ),

                if (widget.sourcesOnly) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      child: AppText(
                        'Saved servers',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  if (_savedSources.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptySources(onAdd: _showAddMenu),
                    )
                  else
                    SliverList.builder(
                      itemCount: _savedSources.length,
                      itemBuilder: (context, index) {
                        final source = _savedSources[index];
                        return SavedSourceTile(
                          key: ValueKey(source.id),
                          name: source.name,
                          subtitle: source.subtitle,
                          icon: source.icon,
                          onTap: () => _openSavedSource(source),
                          onLongPress: source.folder == null
                              ? null
                              : () => _manageFolder(source.folder!),
                        );
                      },
                    ),
                ] else ...[
                  if (_librarySearch.trim().isEmpty)
                    _shelf(
                      label: 'Recently watched',
                      count: recent.length,
                      recent: true,
                      builder: (context, index) => RecentLibraryCard(
                        key: ValueKey('recent:${recent[index].key}'),
                        item: recent[index],
                        onTap: () => _playRecent(recent[index]),
                        onRemove: () => _removeVideo(recent[index].entry),
                      ),
                    ),
                  for (final kind in MediaTitleKind.values)
                    _posterShelf(
                      kind,
                      titles.where((title) => title.kind == kind).toList(),
                    ),
                  if (titles.isEmpty && _librarySearch.trim().isNotEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: AppText('No matching titles'),
                      ),
                    ),
                  if (snapshot.titles.isEmpty && _librarySearch.trim().isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const _EmptyLibrary(),
                            FilledButton.icon(
                              onPressed: _showAddMenu,
                              icon: const Icon(Icons.add),
                              label: const AppText('Add a source'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: MediaQuery.paddingOf(context).bottom + 32,
                  ),
                ),
              ],
            ),
            if (widget.searchActive && !widget.sourcesOnly)
              Positioned(
                top: topInset + kToolbarHeight + 8,
                left: 16,
                right: 16,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Material(
                      key: const Key('library-search-overlay'),
                      color: theme.colorScheme.surface.withValues(alpha: 0.97),
                      elevation: 8,
                      shadowColor: Colors.black.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(18),
                      clipBehavior: Clip.antiAlias,
                      child: TvTextField(
                        key: const Key('library-search-field'),
                        controller: _librarySearchController,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        onChanged: (value) {
                          _librarySearchDebounce?.cancel();
                          _librarySearchDebounce = Timer(
                            const Duration(milliseconds: 250),
                            () {
                              if (mounted) {
                                setState(() => _librarySearch = value);
                              }
                            },
                          );
                        },
                        decoration: InputDecoration(
                          hintText: context.tr(
                            'Search titles, episodes or files',
                          ),
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: IconButton(
                            key: const Key('library-search-close'),
                            tooltip: context.tr('Close'),
                            onPressed: widget.onSearchDismissed,
                            icon: const Icon(Icons.close_rounded),
                          ),
                          filled: true,
                          fillColor: Colors.transparent,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _refreshHome() async {
    setState(() => _refreshing = true);
    try {
      await _loadLibrary();
      await _unifiedLibrary.refresh(_folders);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: AppText('Could not refresh library. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _refreshSources() async {
    setState(() => _refreshing = true);
    try {
      await _loadSavedSources(_folders);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Widget _posterShelf(MediaTitleKind kind, List<MediaTitle> titles) => _shelf(
    label: kind == MediaTitleKind.movie ? 'Movies' : 'TV shows',
    count: titles.length,
    builder: (_, index) => LibraryPosterCard(
      key: ValueKey(titles[index].id),
      title: titles[index],
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => UnifiedTitleDetailsScreen(titleId: titles[index].id),
        ),
      ),
    ),
  );

  Widget _shelf({
    required String label,
    required int count,
    required IndexedWidgetBuilder builder,
    bool recent = false,
  }) {
    return SliverToBoxAdapter(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          // Keep posters readable in narrow split windows, then use the extra
          // room on tablets to show more titles without shrinking phone cards.
          final minimumPosterWidth = width < 600 ? 88.0 : 132.0;
          final columns = ((width - 24) / (minimumPosterWidth + 8))
              .floor()
              .clamp(1, 10);
          final itemWidth = recent
              ? (width * .78).clamp(220.0, 440.0)
              : (width - 32 - (columns - 1) * 8) / columns;
          final scale = MediaQuery.textScalerOf(context);
          final height = recent
              ? itemWidth * 9 / 16 + scale.scale(42) + 16
              : itemWidth * 3 / 2 + scale.scale(38) + 16;
          return Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextButton(
                    onPressed: count == 0
                        ? null
                        : () => _showAll(label, count, builder, recent),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.onSurface,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(48, 48),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppText(
                          label,
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$count',
                          style: TextStyle(
                            fontSize: 17,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          size: 22,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (count > 0)
                  SizedBox(
                    height: height,
                    child: ListView.separated(
                      key: PageStorageKey('shelf:$label'),
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: count,
                      separatorBuilder: (_, _) =>
                          SizedBox(width: recent ? 12 : 8),
                      itemBuilder: (context, index) => SizedBox(
                        width: itemWidth,
                        child: builder(context, index),
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: AppText(
                      recent
                          ? 'Videos you play will appear here.'
                          : 'No titles yet',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showAll(
    String label,
    int count,
    IndexedWidgetBuilder builder,
    bool recent,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: AppText(label)),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final columns = recent
                  ? (constraints.maxWidth / 320).floor().clamp(1, 4)
                  : ((constraints.maxWidth - 24) /
                            ((constraints.maxWidth < 600 ? 88.0 : 132.0) + 8))
                        .floor()
                        .clamp(1, 10);
              final width =
                  (constraints.maxWidth - 32 - 8 * (columns - 1)) / columns;
              return GridView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: count,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 16,
                  mainAxisExtent:
                      width * (recent ? 9 / 16 : 3 / 2) +
                      MediaQuery.textScalerOf(context).scale(recent ? 58 : 54),
                ),
                itemBuilder: builder,
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _retryFailedScans(List<ScanProgress> failed) async {
    final ids = failed.map((progress) => progress.rootId).toSet();
    final roots = _folders.where((folder) => ids.contains(folder.id)).toList();
    if (roots.isEmpty) return;
    await _unifiedLibrary.refresh(roots);
  }

  bool _matchesLibrarySearch(
    LibrarySnapshot snapshot,
    MediaTitle title,
    String query,
  ) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    if (title.displayTitle.toLowerCase().contains(needle) ||
        (title.originalTitle?.toLowerCase().contains(needle) ?? false)) {
      return true;
    }
    for (final episode in snapshot.episodes.values) {
      if (episode.titleId == title.id &&
          episode.displayName.toLowerCase().contains(needle)) {
        return true;
      }
    }
    return snapshot
        .filesForTitle(title.id)
        .any((file) => file.originalFileName.toLowerCase().contains(needle));
  }

  Future<void> _openSavedSource(_SavedSource source) async {
    final Widget screen = switch (source.kind) {
      _SavedSourceKind.files => FolderScreen(folder: source.folder!),
      _SavedSourceKind.webdav => WebDavScreen(initialServerId: source.serverId),
      _SavedSourceKind.smb => SmbScreen(initialServerId: source.serverId),
      _SavedSourceKind.ftp => FtpScreen(initialServerId: source.serverId),
      _SavedSourceKind.jellyfin => JellyfinScreen(
        initialServerUrl: source.serverId,
      ),
    };
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
    await _loadLibrary();
  }

  /// Opens the "+" menu: WebDAV server, internal storage, add folder, Jellyfin.
  Future<void> _showAddMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      // Default sheets cap at 9/16 of screen height — in phone landscape that
      // clips the tail of the list. Scroll-controlled + height-capped so all
      // entries stay reachable on any orientation.
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const AppText('WebDAV'),
                  subtitle: const AppText('Add a WebDAV server'),
                  onTap: () => Navigator.of(context).pop('webdav'),
                ),
                // FTP/SFTP browse + playback on every platform (iOS via the
                // Network.framework FTP client / Citadel SFTP in FtpClient.swift).
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const AppText('FTP / SFTP'),
                  subtitle: const AppText('FTP or SFTP file server'),
                  onTap: () => Navigator.of(context).pop('ftp'),
                ),
                ListTile(
                  leading: const Icon(Icons.live_tv_outlined),
                  title: const AppText('Jellyfin'),
                  subtitle: const AppText('Jellyfin / Emby media server'),
                  onTap: () => Navigator.of(context).pop('jellyfin'),
                ),
                if (Platform.isAndroid)
                  ListTile(
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: const AppText('Network shares'),
                    subtitle: const AppText('SMB / NAS shares'),
                    onTap: () => Navigator.of(context).pop('smb'),
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: const AppText('Network shares'),
                    subtitle: const AppText('SMB via the Files app'),
                    onTap: () => Navigator.of(context).pop('smb-ios'),
                  ),
                ListTile(
                  leading: const Icon(Icons.cast_connected_outlined),
                  title: const AppText('DLNA'),
                  subtitle: const AppText(
                    'DLNA / UPnP servers on this network',
                  ),
                  onTap: () => Navigator.of(context).pop('upnp'),
                ),
                ListTile(
                  leading: const Icon(Icons.link_outlined),
                  title: const AppText('Play URL'),
                  subtitle: const AppText('Stream a direct video link'),
                  onTap: () => Navigator.of(context).pop('play-url'),
                ),
                ListTile(
                  leading: const Icon(Icons.video_library_outlined),
                  title: const AppText('Add folder to library'),
                  subtitle: const AppText(
                    'A TV-show folder, a movie folder\u2026',
                  ),
                  onTap: () => Navigator.of(context).pop('add-folder'),
                ),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const AppText('Internal storage'),
                  subtitle: const AppText('Browse files on this device'),
                  onTap: () => Navigator.of(context).pop('storage'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == null) return;
    await _openSource(action);
  }

  /// Navigates to the given source (menu action string). Shared by the "+"
  /// menu and the TV-mode app-bar buttons.
  Future<void> _openSource(String action) async {
    switch (action) {
      case 'webdav':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const WebDavScreen()));
      case 'ftp':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const FtpScreen()));
      case 'jellyfin':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const JellyfinScreen()));
      case 'smb':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SmbScreen()));
        break;
      case 'smb-ios':
        // iOS: SMB goes through the Files app. Picking a folder from the
        // system document picker (which lists Files-app "Connect to Server"
        // shares) bookmarks it as a library folder, so the share shows up on
        // the home grid with a TMDB poster and is browsable/playable.
        await _addFolderToLibrary();
        break;
      case 'upnp':
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const UpnpScreen()));
        break;
      case 'storage':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const FileBrowserScreen()),
        );
      case 'play-url':
        await _playUrlDialog();
      case 'add-folder':
        await _addFolderToLibrary();
    }
  }

  /// Asks for a direct video URL and plays it. The URL is its own stable
  /// resume key, so re-entering the same link continues where it stopped.
  Future<void> _playUrlDialog() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const AppText('Play URL'),
        content: TvTextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: 'https://example.com/video.mp4',
            labelText: context.tr('Video URL'),
          ),
          onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const AppText('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const AppText('Play'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: AppText('Enter a valid http(s) URL')),
      );
      return;
    }
    final last = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    final title = Uri.decodeComponent(last.isNotEmpty ? last : uri.host);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          video: () {
            final fi = extractFileInfo(title);
            return VideoItem(
              id: 'url_${url.hashCode}',
              title: title,
              uri: url,
              resumeKey: 'url:$url',
              duration: Duration.zero,
              videoCodec: fi.videoCodec,
              audioCodec: fi.audioCodec,
              audioChannels: fi.audioChannels,
              resolution: fi.resolution,
              hdrHint: fi.hdrHint,
            );
          }(),
        ),
      ),
    );
  }

  /// Percent-encodes each path segment (mirrors `_encodePath` in
  /// `webdav_screen.dart`).
  static String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 72,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            AppText(
              'Nothing yet',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            AppText(
              'Videos you play will appear here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptySources extends StatelessWidget {
  const _EmptySources({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_outlined,
              size: 64,
              color: colors.onSurfaceVariant.withValues(alpha: .6),
            ),
            const SizedBox(height: 16),
            const AppText(
              'No saved servers',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            AppText(
              'Tap + to add a source.',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const AppText('Add a source'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _SavedSourceKind { files, webdav, smb, ftp, jellyfin }

class _SavedSource {
  const _SavedSource({
    required this.id,
    required this.kind,
    required this.name,
    required this.subtitle,
    required this.icon,
    this.serverId,
    this.folder,
  });

  final String id;
  final _SavedSourceKind kind;
  final String name;
  final String subtitle;
  final IconData icon;
  final String? serverId;
  final LibraryFolder? folder;
}

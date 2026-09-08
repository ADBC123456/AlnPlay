import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/home_screen.dart';
import 'screens/player_screen.dart';
import 'screens/settings_screen.dart';
import 'models/video_item.dart';
import 'services/jellyfin_client.dart';
import 'services/open_intent.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'l10n/app_localizations.dart';
import 'widgets/liquid_glass_dock.dart';

/// Used by the "Open with" intent handler to navigate without a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Route observer so screens (e.g. Home) can refresh when a pushed route above
/// them pops back (file browser → Home, player → Home, "Open with" → Home).
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

class AlnPlayApp extends StatefulWidget {
  const AlnPlayApp({super.key});

  @override
  State<AlnPlayApp> createState() => _AlnPlayAppState();
}

class _AlnPlayAppState extends State<AlnPlayApp> {
  @override
  void initState() {
    super.initState();
    AppLocaleController.instance.addListener(_appStateChanged);
    AppThemeController.instance.addListener(_appStateChanged);
    _listenForIntents();
  }

  void _appStateChanged() => setState(() {});

  @override
  void dispose() {
    AppLocaleController.instance.removeListener(_appStateChanged);
    AppThemeController.instance.removeListener(_appStateChanged);
    super.dispose();
  }

  Future<void> _listenForIntents() async {
    final service = OpenIntentService.instance;
    service.intents.listen((intent) async {
      final navigator = appNavigatorKey.currentState;
      if (navigator == null) return;
      final base = intent.toVideoItem();
      // Jellyfin "Open in external player": the raw stream URL carries no
      // external subtitle tracks, so re-match it to a saved server + item and
      // attach the sidecars the same way in-app playback does. Best-effort —
      // falls back to the raw URL on any failure.
      final video = await _enrichIntentVideo(base);
      if (!mounted) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(video: video ?? base),
        ),
      );
    });
    // Fetches the intent that launched the app (if any).
    await service.init();
  }

  /// Enriches an "Open with" intent's bare [VideoItem] with Jellyfin external
  /// subtitles when its URI is a saved server's direct-play stream URL.
  /// Returns null (raw [video] plays untouched) when it isn't or on any error.
  Future<VideoItem?> _enrichIntentVideo(VideoItem video) async {
    final uri = video.uri;
    if (uri == null || !uri.startsWith('http')) return null;
    try {
      return await JellyfinClient().enrichJellyfinStreamVideoItem(
        url: uri,
        title: video.title,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AlnPlay',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: AppThemeController.instance.themeMode,
      locale: AppLocaleController.instance.locale,
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      navigatorKey: appNavigatorKey,
      navigatorObservers: [appRouteObserver],
      home: const RootShell(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _selectedIndex = 0;

  /// When the root back press happened, for the double-back-to-exit pattern.
  DateTime? _lastBackPress;

  /// Bumped whenever the Library tab is (re)selected so the Home screen can
  /// reload its "Continue watching" list even though IndexedStack keeps it
  /// alive (playing from the file browser/WebDAV never pushes through Home).
  final ValueNotifier<int> _homeRefreshTick = ValueNotifier(0);
  bool _searchActive = false;
  int _indexBeforeSearch = 0;

  @override
  void dispose() {
    _homeRefreshTick.dispose();
    super.dispose();
  }

  /// Root-route back press: first tap shows a "Press back again to exit"
  /// snackbar; a second tap within 2 s exits the app. Back presses while any
  /// route is pushed above (player, browsers, dialogs) pop those normally and
  /// never reach this handler.
  void _handleRootBack() {
    if (_searchActive) {
      _closeSearch();
      return;
    }
    final now = DateTime.now();
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: AppText('Press back again to exit'),
            duration: Duration(seconds: 2),
          ),
        );
    } else {
      SystemNavigator.pop();
    }
  }

  void _openSearch() {
    setState(() {
      _indexBeforeSearch = _selectedIndex;
      _selectedIndex = 0;
      _searchActive = true;
    });
  }

  void _closeSearch() {
    setState(() {
      _searchActive = false;
      _selectedIndex = _indexBeforeSearch;
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final dockHeight = LiquidGlassDock.heightFor(mediaQuery.textScaler);
    final dockReserve = dockHeight + 24;
    // Android edge-to-edge reports `padding.top == 0` (transparent status
    // bar), so SliverAppBar/AppBar won't push content below the status bar.
    // Map the real status-bar inset (`viewPadding`) into `padding` for the
    // library/settings tabs so they never clash with the status bar.
    final padded = mediaQuery.copyWith(
      padding: mediaQuery.padding.copyWith(
        top: mediaQuery.viewPadding.top,
        bottom: mediaQuery.viewPadding.bottom + dockReserve,
      ),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.systemOverlayStyle(Theme.of(context).brightness),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _handleRootBack();
        },
        child: Scaffold(
          // Search is a floating action over the media library. Keep the
          // library at its normal height while the IME covers the lower part
          // of the screen, otherwise the nested home scroll view can collapse
          // to an apparently empty page on tall phone keyboards.
          resizeToAvoidBottomInset: false,
          extendBody: true,
          body: MediaQuery(
            data: padded,
            child: IndexedStack(
              index: _selectedIndex == 2 ? 1 : 0,
              children: [
                HomeScreen(
                  refreshTick: _homeRefreshTick,
                  searchActive: _searchActive,
                  onSearchDismissed: _closeSearch,
                  sourcesOnly: _selectedIndex == 1,
                ),
                const SettingsScreen(),
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            minimum: const EdgeInsets.symmetric(horizontal: 16),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Center(
                heightFactor: 1,
                child: LiquidGlassDock(
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: (index) {
                    setState(() {
                      _selectedIndex = index;
                      _searchActive = false;
                    });
                    if (index == 0) _homeRefreshTick.value++;
                  },
                  onSearch: () {
                    if (_searchActive) {
                      _closeSearch();
                    } else {
                      _openSearch();
                    }
                  },
                  searchActive: _searchActive,
                  labels: [
                    context.tr('Library'),
                    context.tr('Source library'),
                    context.tr('My'),
                  ],
                  searchLabel: context.tr('Search'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

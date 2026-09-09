import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dream_player/app.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/screens/file_browser_screen.dart';
import 'package:dream_player/screens/player_screen.dart';
import 'package:dream_player/widgets/format_chip.dart';
import 'package:dream_player/services/cache_quota_manager.dart';

void main() {
  testWidgets('resource library shows saved WebDAV servers as shortcuts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var openedServer = '';
    var listServerCalls = 0;
    const channel = MethodChannel('dreamplayer/webdav');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'listServers') {
        listServerCalls++;
        return [
          {
            'id': 'server-j',
            'name': 'j',
            'url': 'http://192.168.6.213:5244/dav',
            'username': '',
            'hasPassword': false,
          },
        ];
      }
      if (call.method == 'listDirectory') {
        openedServer = (call.arguments as Map)['id'] as String;
        return <Map<String, Object?>>[];
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await tester.pumpWidget(const AlnPlayApp());
    await tester.pumpAndSettle();
    expect(listServerCalls, greaterThan(0));
    await tester.tap(find.text('资源库'));
    await tester.pumpAndSettle();

    expect(find.text('已保存的服务器'), findsOneWidget);
    expect(find.text('j'), findsOneWidget);
    expect(find.text('http://192.168.6.213:5244/dav'), findsOneWidget);
    expect(find.text('凡人修仙传'), findsNothing);

    await tester.tap(find.text('j'));
    await tester.pumpAndSettle();
    expect(openedServer, 'server-j');
  });

  testWidgets('App shows library and settings shell', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const AlnPlayApp());

    expect(find.text('AlnPlay'), findsOneWidget);
    expect(find.text('最近观看'), findsOneWidget);
    expect(find.text('电影'), findsOneWidget);
    expect(find.text('动漫'), findsOneWidget);
    expect(find.text('电视剧'), findsOneWidget);
    expect(find.text('媒体库'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('资源库'), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.byIcon(Icons.search), findsNothing);
  });

  testWidgets('Dock search owns library search and returns from source tab', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const AlnPlayApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.search_rounded).last);
    await tester.pumpAndSettle();
    expect(find.text('搜索影片、剧集或文件'), findsOneWidget);
    expect(find.byKey(const Key('library-search-overlay')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ModalBarrier &&
            widget.color != null &&
            widget.color!.a > 0,
      ),
      findsNothing,
    );
    expect(find.text('最近观看'), findsOneWidget);
    expect(find.text('电影'), findsOneWidget);
    expect(find.text('电视剧'), findsOneWidget);

    await tester.tap(find.text('资源库'));
    await tester.pumpAndSettle();
    expect(find.text('搜索影片、剧集或文件'), findsNothing);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    expect(find.text('搜索影片、剧集或文件'), findsOneWidget);
    expect(find.text('AlnPlay'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.search_rounded).last);
    await tester.pumpAndSettle();
    expect(find.text('搜索影片、剧集或文件'), findsNothing);
    expect(find.text('AlnPlay'), findsNothing);
    expect(find.text('资源库'), findsNWidgets(2));
  });

  testWidgets('Search close button restores My tab without masking home', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const AlnPlayApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('外观'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-search-overlay')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ModalBarrier &&
            widget.color != null &&
            widget.color!.a > 0,
      ),
      findsNothing,
    );
    expect(find.text('AlnPlay'), findsOneWidget);
    expect(find.text('电影'), findsOneWidget);

    await tester.tap(find.byKey(const Key('library-search-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-search-overlay')), findsNothing);
    expect(find.text('外观'), findsOneWidget);
  });

  testWidgets('Settings omit support, about, and maker content', (
    tester,
  ) async {
    await tester.pumpWidget(const AlnPlayApp());

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('支持'), findsNothing);
    expect(find.text('关于'), findsNothing);
    expect(find.text('版本'), findsNothing);
    expect(find.text('开源许可'), findsNothing);
    expect(find.textContaining('Mangesh Ghodke'), findsNothing);
  });

  testWidgets('Clear cache shows a confirmation and confirms', (tester) async {
    // Construct inside the widget test's fake-async zone so its serialized
    // cache futures are scheduled by the same clock as the UI.
    CacheQuotaManager.instanceForTesting = CacheQuotaManager(roots: []);
    addTearDown(() {
      CacheQuotaManager.instanceForTesting?.dispose();
      CacheQuotaManager.instanceForTesting = null;
    });
    // The dreamplayer/cache channel is only registered natively; in the test
    // binding an unhandled channel never completes, so mock it to return 0.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dreamplayer/cache'),
      (call) async => 0,
    );
    await tester.pumpWidget(const AlnPlayApp());

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('清除缓存'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除缓存'));
    await tester.pumpAndSettle();

    expect(find.text('清除缓存？'), findsOneWidget);
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();

    expect(find.text('缓存已清除'), findsOneWidget);
    expect(find.text('缓存图片和临时文件已清除'), findsOneWidget);
  });

  testWidgets('Tapping a video opens the player with codec chips', (
    tester,
  ) async {
    const video = VideoItem(
      id: '1',
      title: 'Sonic Anthem (IMAX)',
      path: '/storage/emulated/0/Download/video/test.mkv',
      duration: Duration(seconds: 50),
      videoCodec: 'h264',
      audioCodec: 'dts_hd',
      audioProfile: 'MA',
      audioChannels: '5.1',
    );
    await tester.pumpWidget(
      const MaterialApp(home: PlayerScreen(video: video)),
    );

    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byType(FormatChip), findsWidgets);
    expect(find.text('DTS-HD MA 5.1'), findsOneWidget);
  });

  testWidgets('No overflow on small phone screen', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const AlnPlayApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('No overflow on tablet screen', (tester) async {
    tester.view.physicalSize = const Size(1024 * 2, 1366 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const AlnPlayApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('No overflow on landscape phone', (tester) async {
    tester.view.physicalSize = const Size(640 * 2, 360 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const AlnPlayApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('+ menu shows every entry in phone landscape', (tester) async {
    // Default modal bottom sheets cap at 9/16 of screen height; in phone
    // landscape that clipped the tail of the + menu (regression: the sheet
    // used a non-scrollable Wrap). The sheet is now scroll-controlled.
    tester.view.physicalSize = const Size(800 * 2, 360 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const AlnPlayApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('资源库'));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();

    expect(find.text('WebDAV'), findsOneWidget);
    expect(find.text('FTP / SFTP'), findsOneWidget);
    expect(find.text('Jellyfin'), findsOneWidget);
    expect(find.text('网络共享'), findsOneWidget);
    expect(find.text('DLNA'), findsOneWidget);
    // Tail entries live below the fold at this height — scroll to them.
    await tester.scrollUntilVisible(
      find.text('添加文件夹到媒体库'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('添加文件夹到媒体库'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('内部存储'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('内部存储'), findsOneWidget);
  });

  testWidgets('No overflow with large text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(const AlnPlayApp());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('File browser back button goes up one folder at a time', (
    tester,
  ) async {
    const channel = MethodChannel('dreamplayer/files');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'hasAllFilesAccess':
          return true;
        case 'getStorageRoots':
          return [
            {
              'name': 'Internal storage',
              'path': '/storage/emulated/0',
              'isDirectory': true,
              'size': 0,
            },
          ];
        case 'listDirectory':
          Map<String, dynamic> dir(String name, String path) => {
            'name': name,
            'path': path,
            'isDirectory': true,
            'size': 0,
          };
          return switch (call.arguments['path'] as String) {
            '/storage/emulated/0' => [
              dir('Download', '/storage/emulated/0/Download'),
            ],
            '/storage/emulated/0/Download' => [
              dir('Movies', '/storage/emulated/0/Download/Movies'),
            ],
            _ => <Map<String, dynamic>>[],
          };
        default:
          return null;
      }
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: FileBrowserScreen()));
    await tester.pumpAndSettle();

    // Roots list.
    expect(find.text('Browse files'), findsOneWidget);
    expect(find.text('Internal storage'), findsOneWidget);

    // Enter internal storage -> Download listing.
    await tester.tap(find.text('Internal storage'));
    await tester.pumpAndSettle();
    expect(find.text('Download'), findsOneWidget);

    // Enter Download -> Movies listing.
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Movies'), findsOneWidget);

    // Enter Movies -> empty folder.
    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();

    // Back -> Download listing (parent of Movies is a plain folder).
    await tester.tap(find.byTooltip('Up'));
    await tester.pumpAndSettle();
    expect(find.text('Movies'), findsOneWidget);

    // Back -> internal storage contents (parent of Download IS the root):
    // must NOT skip to the 'Browse files' roots list.
    await tester.tap(find.byTooltip('Up'));
    await tester.pumpAndSettle();
    expect(find.text('Browse files'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Internal storage'), findsNothing);

    // Back -> roots list.
    await tester.tap(find.byTooltip('Up'));
    await tester.pumpAndSettle();
    expect(find.text('Browse files'), findsOneWidget);
  });
}

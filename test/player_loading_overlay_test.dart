import 'package:dream_player/widgets/player_loading_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('dreamplayer/network_speed');
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget host(Widget child, {Locale locale = const Locale('en')}) =>
      MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: child),
      );

  const opening = PlayerLoadingOverlay(
    videoLoading: true,
    preparingVideo: true,
    bufferedAhead: Duration.zero,
    danmakuLoading: true,
    danmakuLabel: 'Matching comments…',
  );

  testWidgets(
    'initial preparation has both stages without fabricated percent',
    (tester) async {
      await tester.pumpWidget(host(opening));
      expect(find.text('Preparing video…'), findsOneWidget);
      expect(find.text('Matching comments…'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
      expect(find.textContaining('%'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('shows actual buffer ahead and determinate comment progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const PlayerLoadingOverlay(
          videoLoading: true,
          preparingVideo: false,
          bufferedAhead: Duration(milliseconds: 12500),
          danmakuLoading: true,
          danmakuLabel: 'Downloading comments · 50%',
          danmakuProgress: .5,
        ),
      ),
    );
    expect(find.text('12.5 s buffered ahead'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .5,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows measured app receive rate during loading', (tester) async {
    var bytes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => bytes);
    await tester.pumpWidget(host(opening));
    await tester.pump();
    bytes = 2048;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('App download ·'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'comment-only loading stays above video and does not intercept taps',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                ),
              ),
              const Positioned.fill(
                child: PlayerLoadingOverlay(
                  videoLoading: false,
                  preparingVideo: false,
                  bufferedAhead: Duration.zero,
                  danmakuLoading: true,
                  danmakuLabel: 'Downloading comments…',
                  danmakuBytesPerSecond: 2048,
                ),
              ),
            ],
          ),
        ),
      );
      expect(find.text('Buffering video…'), findsNothing);
      expect(find.text('Comments average · 2.0 KiB/s'), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.text('Downloading comments…')));
      expect(taps, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('small landscape, large text and Chinese do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(568, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(568, 320),
            textScaler: TextScaler.linear(2),
          ),
          child: opening,
        ),
        locale: const Locale('zh'),
      ),
    );
    expect(find.text('正在准备视频…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('binary rate units and invalid samples are explicit', () {
    expect(PlayerLoadingOverlay.formatRate(0), '0.0 KiB/s');
    expect(PlayerLoadingOverlay.formatRate(1024), '1.0 KiB/s');
    expect(PlayerLoadingOverlay.formatRate(1048576), '1.00 MiB/s');
    expect(PlayerLoadingOverlay.formatRate(double.nan), '—');
    expect(PlayerLoadingOverlay.formatRate(-1), '—');
  });
}

import 'package:dream_player/widgets/player_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ControlsHarness {
  final focusNode = FocusNode();
  final calls = <String, int>{};

  void record(String action) =>
      calls.update(action, (count) => count + 1, ifAbsent: () => 1);

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(800, 360),
    double textScale = 1,
    bool visible = true,
    bool locked = false,
    bool playing = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => record('video'),
                  onDoubleTap: () => record('videoDouble'),
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
              Positioned.fill(
                child: PlayerChrome(
                  visible: visible,
                  title:
                      'A long episode title that must fit a narrow phone screen',
                  badges: const [Text('Dolby Vision'), Text('DTS-HD MA 5.1')],
                  timeline: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('00:03/24:28'),
                      Slider(
                        key: const ValueKey('timeline'),
                        value: .25,
                        onChanged: (_) => record('seek'),
                      ),
                    ],
                  ),
                  playing: playing,
                  completed: false,
                  locked: locked,
                  danmakuVisible: true,
                  fullscreen: true,
                  isTv: false,
                  speed: '1.5×',
                  resolution: '1080P',
                  playFocusNode: focusNode,
                  onFocus: () {},
                  onBack: () => record('back'),
                  onPlay: () => record('play'),
                  onNext: () => record('next'),
                  onDanmaku: () => record('danmaku'),
                  onDanmakuSettings: () => record('danmakuSettings'),
                  onSubtitles: () => record('subtitles'),
                  onEpisodes: () => record('episodes'),
                  onSpeed: () => record('speed'),
                  onInfo: () => record('info'),
                  onAudio: () => record('audio'),
                  onMore: () => record('more'),
                  onLock: () => record('lock'),
                  onFullscreen: () => record('fullscreen'),
                  onRewind: () => record('rewind'),
                  onForward: () => record('forward'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  late _ControlsHarness harness;

  setUp(() => harness = _ControlsHarness());
  tearDown(() => harness.focusNode.dispose());

  for (final scenario in [
    (name: 'portrait phone', size: const Size(360, 640), scale: 1.0),
    (name: 'landscape phone', size: const Size(800, 360), scale: 1.0),
    (name: 'large text phone', size: const Size(360, 640), scale: 2.0),
    (name: 'large text landscape', size: const Size(800, 360), scale: 2.0),
    (name: 'tablet', size: const Size(1024, 768), scale: 1.0),
  ]) {
    testWidgets('${scenario.name} controls fit without overflow', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await harness.mount(
        tester,
        size: scenario.size,
        textScale: scenario.scale,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('DTS-HD MA 5.1'), findsOneWidget);
      expect(find.text('Select episode'), findsOneWidget);
      expect(find.text('Subtitles'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      final fullscreen = find.byTooltip('Fullscreen');
      expect(fullscreen.hitTestable(), findsOneWidget);
      await tester.tap(fullscreen);
      expect(harness.calls['fullscreen'], 1);
    });
  }

  testWidgets('play and pause stay at the bottom and leave the center free', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final playing in [false, true]) {
      await harness.mount(tester, playing: playing);
      final button = find.byTooltip(playing ? 'Pause' : 'Play');
      expect(button, findsOneWidget);
      expect(tester.getCenter(button).dy, greaterThan(280));
      expect(
        find.byIcon(playing ? Icons.pause : Icons.play_arrow),
        findsOneWidget,
      );
      await tester.tap(button);
      await tester.tapAt(const Offset(400, 180));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(harness.calls['play'], 2);
    expect(harness.calls['video'], 2);
  });

  for (final visible in [true, false]) {
    testWidgets(
      'center double tap passes through ${visible ? 'visible' : 'hidden'} chrome in small landscape',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await harness.mount(
          tester,
          size: const Size(800, 360),
          textScale: 2,
          visible: visible,
        );

        await tester.tapAt(const Offset(400, 180));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(const Offset(400, 180));
        await tester.pumpAndSettle();

        expect(harness.calls['videoDouble'], 1);
        expect(tester.takeException(), isNull);
        if (visible) {
          await tester.tap(find.byTooltip('Play'));
          expect(harness.calls['play'], 1);
        }
      },
    );
  }

  testWidgets(
    'hidden controls pass video taps through their former positions',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await harness.mount(tester);
      final positions = [
        tester.getCenter(find.byTooltip('Play')),
        tester.getCenter(find.byTooltip('More')),
        tester.getCenter(find.byTooltip('Lock')),
        const Offset(400, 180),
      ];
      await harness.mount(tester, visible: false);
      for (final position in positions) {
        await tester.tapAt(position);
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(harness.calls, {'video': 4});
      expect(find.byTooltip('Play').hitTestable(), findsNothing);
      expect(harness.focusNode.canRequestFocus, isFalse);
    },
  );

  testWidgets(
    'locked controls disable transport and seeking but allow unlock',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await harness.mount(tester, locked: true);
      for (final button in tester.widgetList<IconButton>(
        find.byType(IconButton),
      )) {
        if (button.tooltip == 'Unlock' || button.tooltip == 'Back') {
          expect(button.onPressed, isNotNull);
        } else {
          expect(button.onPressed, isNull, reason: button.tooltip);
        }
      }
      for (final button in tester.widgetList<TextButton>(
        find.byType(TextButton),
      )) {
        expect(button.onPressed, isNull);
      }
      await tester.tap(find.byTooltip('Play'));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('timeline'))),
      );
      expect(harness.calls['play'], isNull);
      expect(harness.calls['seek'], isNull);
      await tester.tap(find.byTooltip('Unlock'));
      expect(harness.calls['lock'], 1);
      await tester.tap(find.byTooltip('Back'));
      expect(harness.calls['back'], 1);
    },
  );
}

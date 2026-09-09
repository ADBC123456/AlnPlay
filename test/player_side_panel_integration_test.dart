import 'package:dream_player/danmaku/settings/danmaku_display_settings.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/screens/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: PlayerScreen(
          video: VideoItem(
            id: 'panel-test',
            duration: Duration.zero,
            title: 'Episode',
            uri: 'https://example.invalid/episode.mp4',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final entry in ['Subtitles', 'Select episode', 'Danmaku settings']) {
    testWidgets(
      '$entry opens a dismissible right sidebar from the real player',
      (tester) async {
        await mount(tester);
        final trigger = entry == 'Subtitles' || entry == 'Select episode'
            ? find.widgetWithText(TextButton, entry)
            : find.byTooltip(entry);
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        final panel = find.byKey(const Key('player-side-panel'));
        expect(panel, findsOneWidget);
        expect(tester.getRect(panel).right, 960);
        expect(tester.getRect(panel).left, greaterThan(480));
        expect(find.byType(BottomSheet), findsNothing);
        await tester.tap(find.byKey(const Key('player-side-panel-close')));
        await tester.pumpAndSettle();
        expect(panel, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('danmaku sidebar accumulates settings and saves on close', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byTooltip('Danmaku settings'));
    await tester.pumpAndSettle();
    Slider slider(String key) => tester.widget<Slider>(
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(Slider)),
    );
    slider('danmaku-display-area').onChanged!(.75);
    await tester.pump();
    slider('danmaku-opacity').onChanged!(.4);
    await tester.pump();
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    await tester.tap(find.byKey(const Key('player-side-panel-close')));
    await tester.pumpAndSettle();
    final settings = await DanmakuDisplaySettingsStore.load();
    expect(settings.displayArea, .75);
    expect(settings.opacity, .4);
    await tester.pumpWidget(const SizedBox());
  });
}

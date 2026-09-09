import 'package:dream_player/danmaku/settings/danmaku_display_settings.dart';
import 'package:dream_player/l10n/app_localizations.dart';
import 'package:dream_player/widgets/player_danmaku_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppLocaleController.instance.setLanguage('zh');
  });

  Widget app(
    DanmakuDisplaySettings settings,
    ValueChanged<DanmakuDisplaySettings> onChanged, {
    double textScale = 1,
    Locale locale = const Locale('zh'),
  }) {
    return MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: PlayerDanmakuPanel(settings: settings, onChanged: onChanged),
        ),
      ),
    );
  }

  testWidgets('shows the basic controls and expands advanced controls', (
    tester,
  ) async {
    await tester.pumpWidget(app(const DanmakuDisplaySettings(), (_) {}));

    expect(find.text('显示区域'), findsOneWidget);
    expect(find.text('不透明度'), findsOneWidget);
    expect(find.byKey(const Key('danmaku-font-size')), findsNothing);

    await tester.tap(find.byKey(const Key('danmaku-more-toggle')));
    await tester.pump();

    expect(find.byKey(const Key('danmaku-font-size')), findsOneWidget);
    expect(find.byKey(const Key('danmaku-scroll-speed')), findsOneWidget);
  });

  testWidgets('slider and type chips emit copied settings', (tester) async {
    final changes = <DanmakuDisplaySettings>[];
    await tester.pumpWidget(app(const DanmakuDisplaySettings(), changes.add));

    await tester.tap(find.byKey(const Key('danmaku-type-top')));
    expect(changes.single.showTop, isFalse);
    expect(changes.single.showBottom, isTrue);
    expect(changes.single.showScroll, isTrue);

    changes.clear();
    final slider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const Key('danmaku-opacity')),
        matching: find.byType(Slider),
      ),
    );
    slider.onChanged!(.4);
    expect(changes.single.opacity, .4);
    expect(changes.single.displayArea, .5);
  });

  testWidgets('remains scrollable at 2x text scale on a phone', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      app(const DanmakuDisplaySettings(), (_) {}, textScale: 2),
    );
    await tester.tap(find.byKey(const Key('danmaku-more-toggle')));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(ListView), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses English localized copy', (tester) async {
    await tester.pumpWidget(
      app(const DanmakuDisplaySettings(), (_) {}, locale: const Locale('en')),
    );
    expect(find.text('Display area'), findsOneWidget);
    expect(find.text('Danmaku type'), findsOneWidget);
  });
}

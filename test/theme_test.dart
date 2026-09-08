import 'package:dream_player/theme/app_theme.dart';
import 'package:dream_player/theme/theme_controller.dart';
import 'package:dream_player/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('missing and unknown preferences safely use system mode', () async {
    for (final saved in <String?>[null, 'unsupported']) {
      SharedPreferences.setMockInitialValues({
        AppThemeController.preferenceKey: ?saved,
      });
      final controller = AppThemeController();
      await controller.init();
      expect(controller.themeMode, ThemeMode.system);
      controller.dispose();
    }
  });

  test(
    'all modes survive restart and rapid changes preserve last choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = AppThemeController();
      for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system]) {
        await controller.setThemeMode(mode);
        final restored = AppThemeController();
        await restored.init();
        expect(restored.themeMode, mode);
        restored.dispose();
      }
      await Future.wait([
        controller.setThemeMode(ThemeMode.dark),
        controller.setThemeMode(ThemeMode.light),
        controller.setThemeMode(ThemeMode.system),
      ]);
      expect(controller.themeMode, ThemeMode.system);
      expect(
        (await SharedPreferences.getInstance()).getString(
          AppThemeController.preferenceKey,
        ),
        'system',
      );
      controller.dispose();
    },
  );

  testWidgets(
    'system follows platform changes while explicit choice stays fixed',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = AppThemeController();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      Brightness? renderedBrightness;
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => MaterialApp(
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: controller.themeMode,
            home: Builder(
              builder: (context) {
                renderedBrightness = Theme.of(context).brightness;
                return const Scaffold(body: Text('Theme'));
              },
            ),
          ),
        ),
      );
      expect(renderedBrightness, Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(renderedBrightness, Brightness.dark);
      await tester.runAsync(() => controller.setThemeMode(ThemeMode.light));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(renderedBrightness, Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(renderedBrightness, Brightness.light);
      await tester.runAsync(() => controller.setThemeMode(ThemeMode.system));
      await tester.pumpAndSettle();
      expect(renderedBrightness, Brightness.dark);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  test(
    'primary and secondary text remain readable across neutral surfaces',
    () {
      double contrast(Color a, Color b) {
        final one = a.computeLuminance();
        final two = b.computeLuminance();
        return one > two
            ? (one + .05) / (two + .05)
            : (two + .05) / (one + .05);
      }

      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final colors = theme.colorScheme;
        for (final surface in [colors.surface, colors.surfaceContainer]) {
          expect(
            contrast(colors.onSurface, surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(colors.onSurfaceVariant, surface),
            greaterThanOrEqualTo(4.5),
          );
        }
        expect(
          contrast(colors.primary, colors.onPrimary),
          greaterThanOrEqualTo(4.5),
        );
      }
    },
  );

  for (final size in [
    const Size(320, 720),
    const Size(834, 1194),
    const Size(1194, 834),
  ]) {
    testWidgets('settings theme choice remains usable at $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(() => AppThemeController.instance.init());
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(2),
              padding: const EdgeInsets.only(bottom: 110),
            ),
            child: const Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      // Settings starts best-effort account/network refreshes. Use bounded
      // frames so a slow background future cannot make a layout test hang.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Theme'));
      await tester.tap(find.text('Theme'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Follow system'), findsWidgets);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Light'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Mangesh Ghodke'), findsNothing);
      expect(find.text('Support'), findsNothing);
      expect(find.text('About'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

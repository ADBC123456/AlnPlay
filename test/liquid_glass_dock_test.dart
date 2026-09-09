import 'package:dream_player/widgets/liquid_glass_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host({
    double width = 375,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    int selectedIndex = 0,
    ValueChanged<int>? onDestinationSelected,
    VoidCallback? onSearch,
    bool disableAnimations = false,
  }) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 800),
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LiquidGlassDock(
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected ?? (_) {},
                onSearch: onSearch ?? () {},
                labels: const ['媒体库', '资源库', '我的'],
                searchLabel: '搜索',
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('tabs and separate search expose distinct accessible actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    int? selected;
    var searches = 0;
    await tester.pumpWidget(
      host(
        onDestinationSelected: (value) => selected = value,
        onSearch: () => searches++,
      ),
    );

    await tester.tap(find.text('资源库'));
    expect(selected, 1);
    await tester.tap(find.byIcon(Icons.search_rounded));
    expect(searches, 1);
    expect(selected, 1, reason: 'Search must not act as a fourth destination.');
    expect(
      tester.getSemantics(find.bySemanticsLabel('媒体库')),
      matchesSemantics(
        label: '媒体库',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('phone and iPad windows fit with large text in either theme', (
    tester,
  ) async {
    for (final width in [320.0, 375.0, 600.0, 834.0, 1194.0]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      for (final scale in [1.0, 2.0, 3.0]) {
        for (final brightness in Brightness.values) {
          await tester.pumpWidget(
            host(width: width, textScale: scale, brightness: brightness),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'width $width, scale $scale, $brightness',
          );
          final dock = tester.getSize(find.byType(Row).first);
          expect(dock.width, lessThanOrEqualTo(560));
          for (final label in ['媒体库', '资源库', '我的']) {
            final action = find.ancestor(
              of: find.text(label),
              matching: find.byType(InkWell),
            );
            expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
          }
          expect(
            tester.getSize(
              find.ancestor(
                of: find.byIcon(Icons.search_rounded),
                matching: find.byType(InkWell),
              ),
            ),
            const Size(64, 64),
          );
        }
      }
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('dragging the lens commits the nearest destination once', (
    tester,
  ) async {
    final selected = <int>[];
    await tester.pumpWidget(host(onDestinationSelected: selected.add));
    await tester.pump();

    await tester.drag(find.text('媒体库'), const Offset(190, 0));
    await tester.pump(const Duration(milliseconds: 250));

    expect(selected, [2]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps the selection lens usable', (tester) async {
    await tester.pumpWidget(host(disableAnimations: true));
    await tester.pumpWidget(host(disableAnimations: true, selectedIndex: 2));
    await tester.pump();

    expect(find.byKey(const Key('dock-selection-lens')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

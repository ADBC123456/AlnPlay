import 'dart:ui' as ui;

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
    bool highContrast = false,
  }) => MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 800),
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
        highContrast: highContrast,
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

  testWidgets('vertical movement and cancelled drags never select a tab', (
    tester,
  ) async {
    final selected = <int>[];
    await tester.pumpWidget(host(onDestinationSelected: selected.add));
    await tester.drag(find.text('媒体库'), const Offset(5, -130));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);

    final start = tester.getCenter(find.text('媒体库'));
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    final lens = tester.getCenter(find.byKey(const Key('dock-selection-lens')));
    expect(lens.dx, closeTo(start.dx, .1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('external selection during a drag wins over the drag target', (
    tester,
  ) async {
    final selected = <int>[];
    await tester.pumpWidget(host(onDestinationSelected: selected.add));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('媒体库')),
    );
    await gesture.moveBy(const Offset(170, 0));
    await tester.pump();
    await tester.pumpWidget(
      host(selectedIndex: 1, onDestinationSelected: selected.add),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(selected, isEmpty);
    expect(
      tester.getCenter(find.byKey(const Key('dock-selection-lens'))).dx,
      closeTo(tester.getCenter(find.text('资源库')).dx, .1),
    );
  });

  testWidgets('a spring can be interrupted and settles without idle frames', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpWidget(host(selectedIndex: 2));
    await tester.pump(const Duration(milliseconds: 90));
    final before = tester.getCenter(
      find.byKey(const Key('dock-selection-lens')),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('资源库')),
    );
    await tester.pump();
    final after = tester.getCenter(
      find.byKey(const Key('dock-selection-lens')),
    );
    expect(after.dx, closeTo(before.dx, .1));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backgrounding clears a held lens and accepts the next tap', (
    tester,
  ) async {
    final selected = <int>[];
    await tester.pumpWidget(host(onDestinationSelected: selected.add));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('媒体库')),
    );
    await gesture.moveBy(const Offset(90, 0));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await gesture.up();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(selected, [2]);
  });

  testWidgets('high contrast uses solid material with the same four actions', (
    tester,
  ) async {
    await tester.pumpWidget(host(highContrast: true));
    expect(find.byType(InkWell), findsNWidgets(4));
    for (final filter in tester.widgetList<BackdropFilter>(
      find.byType(BackdropFilter),
    )) {
      expect(filter.enabled, isFalse);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('parent selection acknowledgement preserves fling velocity', (
    tester,
  ) async {
    Future<double> positionAfterRelease({required bool controlled}) async {
      await tester.pumpWidget(const SizedBox.shrink());
      var selected = 0;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, update) => host(
            selectedIndex: selected,
            onDestinationSelected: (value) {
              if (controlled) update(() => selected = value);
            },
          ),
        ),
      );
      await tester.fling(find.text('媒体库'), const Offset(70, 0), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      return tester.getCenter(find.byKey(const Key('dock-selection-lens'))).dx;
    }

    final uninterrupted = await positionAfterRelease(controlled: false);
    final acknowledged = await positionAfterRelease(controlled: true);
    expect(acknowledged, closeTo(uninterrupted, .1));
    await tester.pumpAndSettle();
  });

  testWidgets('held lens grows without resizing the dock or its actions', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final lens = find.byKey(const Key('dock-selection-lens'));
    Rect paintedLensRect() {
      final box = tester.renderObject<RenderBox>(lens);
      return Rect.fromPoints(
        box.localToGlobal(Offset.zero),
        box.localToGlobal(Offset(box.size.width, box.size.height)),
      );
    }

    final rest = paintedLensRect();
    final dock = tester.getRect(find.byType(LiquidGlassDock));
    final action = tester.getRect(find.byType(InkWell).first);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('媒体库')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    final held = paintedLensRect();
    expect(held.width, greaterThan(rest.width * 1.1));
    expect(held.height, greaterThan(rest.height * 1.2));
    expect(tester.getRect(find.byType(LiquidGlassDock)), dock);
    expect(tester.getRect(find.byType(InkWell).first), action);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(paintedLensRect(), rest);
  });

  testWidgets('dock body and search keep uniform Gaussian frosting', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final frosting = ui.ImageFilter.blur(
      sigmaX: 18,
      sigmaY: 18,
      tileMode: TileMode.clamp,
    );
    expect(
      tester
          .widgetList<BackdropFilter>(find.byType(BackdropFilter))
          .where((widget) => widget.filter == frosting)
          .length,
      2,
    );
  });
}

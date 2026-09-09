import 'package:dream_player/widgets/player_episode_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final items = [
    for (var number = 1; number <= 189; number++)
      PlayerEpisodePanelItem<int>(
        value: number,
        id: 'e$number',
        label: 'Episode $number',
        number: number,
        season: 1,
        available: number != 75,
      ),
    const PlayerEpisodePanelItem<int>(
      value: -1,
      id: 'unknown',
      label: 'Bonus',
      season: 1,
    ),
    const PlayerEpisodePanelItem<int>(
      value: -2,
      id: 'unknown-season',
      label: 'Mystery special',
    ),
  ];

  Future<List<int>> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final selected = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: Scaffold(
          body: PlayerEpisodePanel<int>(
            items: items,
            currentId: 'e74',
            onSelected: (item) => selected.add(item.value),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return selected;
  }

  testWidgets(
    'opens current 50-range, highlights and locates current episode',
    (tester) async {
      addTearDown(tester.view.reset);
      final selected = await mount(tester, const Size(390, 844));
      expect(find.text('51–100'), findsOneWidget);
      expect(find.text('Episode 74'), findsOneWidget);
      expect(find.text('Episode 1'), findsNothing);
      final currentMaterial = tester.widget<Material>(
        find
            .ancestor(
              of: find.text('Episode 74'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(currentMaterial.color, isNot(Colors.transparent));
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        1,
      );
      await tester.tap(find.text('Episode 74'));
      expect(selected, [74]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tablet uses two columns and unavailable gaps stay disabled', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final selected = await mount(tester, const Size(1024, 768));
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      2,
    );
    expect(find.text('Episode 75'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
    await tester.tap(find.text('Episode 75'));
    expect(selected, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('range tabs use actual numbers and preserve unknown episodes', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await mount(tester, const Size(390, 844));
    expect(find.text('1–50'), findsOneWidget);
    expect(find.text('51–100'), findsOneWidget);
    expect(find.text('101–150'), findsOneWidget);
    expect(find.text('151–189'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);
    await tester.ensureVisible(find.text('Unknown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unknown'));
    await tester.pumpAndSettle();
    expect(find.text('Bonus'), findsOneWidget);

    await tester.tap(find.text('Unknown season'));
    await tester.pumpAndSettle();
    expect(find.text('Mystery special'), findsOneWidget);
  });
}

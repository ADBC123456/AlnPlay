import 'package:dream_player/widgets/player_side_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> open(
    WidgetTester tester, {
    required Size size,
    bool nested = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showPlayerSidePanel<void>(
              context: context,
              title: 'Subtitles',
              builder: (panelContext) => Center(
                child: FilledButton(
                  key: const Key('panel-action'),
                  onPressed: nested
                      ? () => Navigator.of(panelContext).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                const Scaffold(body: Text('Subtitle settings')),
                          ),
                        )
                      : null,
                  child: const Text('Action'),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final scenario in [
    (size: const Size(390, 844), width: 351.0),
    (size: const Size(800, 360), width: 384.0),
    (size: const Size(1024, 768), width: 560.0),
  ]) {
    testWidgets('uses responsive edge width at ${scenario.size}', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await open(tester, size: scenario.size);
      expect(
        tester.getSize(find.byKey(const Key('player-side-panel'))).width,
        scenario.width,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('scrim and close button dismiss while nested pages return', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await open(tester, size: const Size(390, 844), nested: true);
    await tester.tap(find.byKey(const Key('panel-action')));
    await tester.pumpAndSettle();
    expect(find.text('Subtitle settings'), findsOneWidget);
    Navigator.of(tester.element(find.text('Subtitle settings'))).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-side-panel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('player-side-panel-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-side-panel')), findsNothing);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('player-side-panel')), findsNothing);
  });
}

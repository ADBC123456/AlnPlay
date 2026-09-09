import 'package:dream_player/widgets/player_gesture_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  int taps = 0;
  int seeks = 0;
  int holds = 0;
  int releases = 0;
  int scales = 0;
  final seekPositions = <Offset>[];

  Future<void> mount(WidgetTester tester) async {
    taps = seeks = holds = releases = scales = 0;
    seekPositions.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerGestureSurface(
          onTap: () => taps++,
          onDoubleTap: (position) {
            seeks++;
            seekPositions.add(position);
          },
          onHoldStart: () => holds++,
          onHoldEnd: () => releases++,
          onScaleStart: (_) => scales++,
          onScaleUpdate: (_) {},
          onScaleEnd: (_) {},
        ),
      ),
    );
  }

  test('seek zones are exclusively the outer quarters', () {
    for (final x in [0.0, 100.0, 199.99]) {
      expect(PlayerGestureSurface.seekDirection(x, 800), -1);
    }
    for (final x in [200.0, 400.0, 600.0]) {
      expect(PlayerGestureSurface.seekDirection(x, 800), 0);
    }
    for (final x in [600.01, 700.0, 800.0]) {
      expect(PlayerGestureSurface.seekDirection(x, 800), 1);
    }
    expect(PlayerGestureSurface.seekDirection(-1, 800), 0);
    expect(PlayerGestureSurface.seekDirection(801, 800), 0);
    expect(PlayerGestureSurface.seekDirection(0, 0), 0);
  });

  for (final x in [100.0, 199.0, 200.0, 400.0, 600.0, 601.0, 700.0]) {
    testWidgets('double tap at x=$x reaches playback/seek handler', (
      tester,
    ) async {
      await mount(tester);
      for (final milliseconds in [0, 100]) {
        final gesture = await tester.createGesture();
        await gesture.down(
          Offset(x, 100),
          timeStamp: Duration(milliseconds: milliseconds),
        );
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        taps,
        1,
        reason: 'The first tap must reveal controls immediately.',
      );
      expect(seeks, 1);
      expect(seekPositions, [Offset(x, 100)]);
    });
  }

  testWidgets('first tap responds on release without a double-tap timeout', (
    tester,
  ) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 100));
    expect(taps, 1);
    expect(seeks, 0);
    await tester.pump(const Duration(milliseconds: 600));
    expect(taps, 1);
  });

  testWidgets('nearby second tap seeks, distant taps stay single', (
    tester,
  ) async {
    await mount(tester);
    Future<void> tap(Offset position, int milliseconds) async {
      final gesture = await tester.createGesture();
      await gesture.down(
        position,
        timeStamp: Duration(milliseconds: milliseconds),
      );
      await gesture.up();
    }

    await tap(const Offset(100, 100), 0);
    await tester.pump(const Duration(milliseconds: 100));
    await tap(const Offset(100, 100), 100);
    expect(taps, 1);
    expect(seeks, 1);
    await tester.pump(const Duration(milliseconds: 400));
    await tap(const Offset(100, 100), 500);
    await tester.pump(const Duration(milliseconds: 100));
    await tap(const Offset(500, 100), 600);
    expect(taps, 3);
    expect(seeks, 1);
  });

  testWidgets('long press starts once and releases without toggling chrome', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 600));
    expect(holds, 1);
    await gesture.up();
    expect(releases, 1);
    expect(taps, 0);
    expect(seeks, 0);
  });

  testWidgets('pointer cancellation always releases temporary speed', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.cancel();
    expect(holds, 1);
    expect(releases, 1);
    expect(taps, 0);
  });

  testWidgets('second finger cancels an active hold', (tester) async {
    await mount(tester);
    final first = await tester.startGesture(const Offset(100, 100), pointer: 1);
    await tester.pump(const Duration(milliseconds: 600));
    final second = await tester.startGesture(
      const Offset(300, 100),
      pointer: 2,
    );
    expect(releases, 1);
    await second.up();
    await first.up();
    expect(releases, 1);
  });

  testWidgets('swipe wins over hold and does not toggle controls', (
    tester,
  ) async {
    await mount(tester);
    await tester.dragFrom(const Offset(100, 100), const Offset(150, 0));
    await tester.pump(const Duration(milliseconds: 600));
    expect(scales, greaterThan(0));
    expect(holds, 0);
    expect(taps, 0);
  });
}

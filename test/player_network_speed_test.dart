import 'dart:async';

import 'package:dream_player/services/player_network_speed.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dreamplayer/network_speed');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('computes positive per-app receive delta', () async {
    var bytes = 1000;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => bytes);
    var micros = 1000000;
    final telemetry = PlayerNetworkSpeedTelemetry(clockMicros: () => micros);
    expect(await telemetry.sample(), isNull);
    bytes += 2000;
    micros += 1000000;
    final rate = await telemetry.sample();
    expect(rate, isNotNull);
    expect(rate, greaterThan(0));
    telemetry.dispose();
  });

  test('counter reset and unavailable values do not produce a rate', () async {
    num? bytes = 5000;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => bytes);
    final telemetry = PlayerNetworkSpeedTelemetry();
    await telemetry.sample();
    bytes = 100;
    expect(await telemetry.sample(), isNull);
    bytes = null;
    expect(await telemetry.sample(), isNull);
    telemetry.dispose();
  });

  test('overlapping samples share one native request', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return 1000;
        });
    final telemetry = PlayerNetworkSpeedTelemetry();
    await Future.wait([telemetry.sample(), telemetry.sample()]);
    expect(calls, 1);
    telemetry.dispose();
  });

  test('plugin failure is reported as unavailable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw MissingPluginException();
        });
    final telemetry = PlayerNetworkSpeedTelemetry();
    expect(await telemetry.sample(), isNull);
    telemetry.dispose();
  });

  test(
    'dispose while native request is pending does not write notifier',
    () async {
      final gate = Completer<num?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) => gate.future);
      final telemetry = PlayerNetworkSpeedTelemetry();
      final pending = telemetry.sample();
      telemetry.dispose();
      gate.complete(1000);
      await pending;
    },
  );

  test('stop while native request is pending clears the baseline', () async {
    final gate = Completer<num?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => gate.future);
    final telemetry = PlayerNetworkSpeedTelemetry();
    final pending = telemetry.sample();
    telemetry.stop();
    gate.complete(1000);
    await pending;
    expect(telemetry.bytesPerSecond.value, isNull);
    telemetry.dispose();
  });

  test('restart does not average time spent stopped', () async {
    var bytes = 1000;
    var micros = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => bytes);
    final telemetry = PlayerNetworkSpeedTelemetry(clockMicros: () => micros);
    await telemetry.sample();
    telemetry.stop();
    micros = 100000000;
    telemetry.start(interval: const Duration(hours: 1));
    await Future<void>.delayed(Duration.zero);
    expect(telemetry.bytesPerSecond.value, isNull);
    bytes += 1000;
    micros += 1000000;
    expect(await telemetry.sample(), 1000);
    telemetry.dispose();
  });

  test('unchanged counter reports a real zero rate', () async {
    var micros = 10;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => 5000);
    final telemetry = PlayerNetworkSpeedTelemetry(clockMicros: () => micros);
    await telemetry.sample();
    micros += 1000000;
    expect(await telemetry.sample(), 0);
    telemetry.dispose();
  });

  test(
    'negative counter is unavailable, then a fresh counter recovers',
    () async {
      num bytes = -1;
      var micros = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => bytes);
      final telemetry = PlayerNetworkSpeedTelemetry(clockMicros: () => micros);
      expect(await telemetry.sample(), isNull);
      bytes = 100;
      micros += 1000000;
      expect(await telemetry.sample(), isNull);
      bytes = 300;
      micros += 1000000;
      expect(await telemetry.sample(), 200);
      telemetry.dispose();
    },
  );
}

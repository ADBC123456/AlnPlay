import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Per-app receive telemetry. Android reports the UID byte counter, which
/// includes Media3, MPV and other network work owned by this app; it is not a
/// measurement of one particular stream. iOS returns unavailable.
class PlayerNetworkSpeedTelemetry {
  PlayerNetworkSpeedTelemetry({
    MethodChannel? channel,
    int Function()? clockMicros,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _clockMicros = clockMicros ?? (() => _stopwatch.elapsedMicroseconds);

  static const _channelName = 'dreamplayer/network_speed';
  static const Duration defaultInterval = Duration(seconds: 1);

  final MethodChannel _channel;
  final int Function() _clockMicros;
  static final Stopwatch _stopwatch = Stopwatch()..start();

  /// Null means not sampled yet, counter unavailable, or counter reset.
  final ValueNotifier<double?> bytesPerSecond = ValueNotifier<double?>(null);
  Timer? _timer;
  Future<void>? _inFlight;
  int? _lastBytes;
  int? _lastAt;
  double? _lastRate;
  int _generation = 0;
  bool _disposed = false;

  double? get lastRateBytesPerSecond => bytesPerSecond.value;

  Future<double?> sample() async {
    if (_disposed) return null;
    final existing = _inFlight;
    if (existing != null) {
      await existing;
      return _lastRate;
    }
    final generation = _generation;
    final future = _sampleOnce(generation);
    _inFlight = future;
    try {
      await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
    return _lastRate;
  }

  Future<void> _sampleOnce(int generation) async {
    num? raw;
    try {
      raw = await _channel.invokeMethod<num>('rxBytes');
    } on PlatformException {
      raw = null;
    } on MissingPluginException {
      raw = null;
    }
    if (_disposed || generation != _generation) return;
    final bytes = raw != null && raw.isFinite && raw >= 0 ? raw.toInt() : null;
    final now = _clockMicros();
    final previousBytes = _lastBytes;
    final previousAt = _lastAt;
    _lastBytes = bytes;
    _lastAt = now;
    if (bytes == null ||
        bytes < 0 ||
        previousBytes == null ||
        previousAt == null) {
      _lastRate = null;
      bytesPerSecond.value = null;
      return;
    }
    final elapsed = (now - previousAt) / Duration.microsecondsPerSecond;
    final delta = bytes - previousBytes;
    if (elapsed <= 0 || delta < 0) {
      _lastRate = null;
      bytesPerSecond.value = null;
      return;
    }
    _lastRate = delta / elapsed;
    bytesPerSecond.value = _lastRate;
  }

  void start({
    Duration interval = defaultInterval,
    void Function(double?)? onSample,
  }) {
    if (_disposed) return;
    stop();
    final generation = _generation;
    unawaited(sample());
    _timer = Timer.periodic(interval, (_) async {
      final rate = await sample();
      if (!_disposed && generation == _generation) onSample?.call(rate);
    });
  }

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _lastBytes = null;
    _lastAt = null;
    _lastRate = null;
    if (!_disposed) bytesPerSecond.value = null;
  }

  void dispose() {
    _disposed = true;
    stop();
    bytesPerSecond.dispose();
  }
}

/// Detailed loading belongs to the first preparation of a video. Seeking,
/// reconnecting or changing subtitles for that video must not bring it back.
class PlayerLoadingState {
  String? _sourceKey;
  bool _ready = false;

  bool get showDetails => !_ready;

  void begin(String sourceKey) {
    if (_sourceKey == sourceKey) return;
    _sourceKey = sourceKey;
    _ready = false;
  }

  void markReady() => _ready = true;
}

/// libmpv's cache-buffering-state is a percentage, not a 0–1 fraction.
double? parseMpvBufferingProgress(String raw) {
  final value = double.tryParse(raw);
  if (value == null || !value.isFinite || value < 0 || value > 100) return null;
  return value / 100;
}

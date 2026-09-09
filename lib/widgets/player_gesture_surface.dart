import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Responds to the first tap immediately. A nearby second tap seeks or toggles
/// playback in the center without
/// making every single tap wait for DoubleTapGestureRecognizer's timeout.
class PlayerGestureSurface extends StatefulWidget {
  const PlayerGestureSurface({
    super.key,
    required this.onTap,
    required this.onDoubleTap,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onScaleStart,
    required this.onScaleUpdate,
    required this.onScaleEnd,
  });

  final VoidCallback onTap;
  final ValueChanged<Offset> onDoubleTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  final GestureScaleStartCallback onScaleStart;
  final GestureScaleUpdateCallback onScaleUpdate;
  final GestureScaleEndCallback onScaleEnd;

  /// Only the outer quarters seek; the middle half toggles playback.
  static int seekDirection(double x, double width) {
    if (width <= 0 || x < 0 || x > width) return 0;
    if (x < width * .25) return -1;
    if (x > width * .75) return 1;
    return 0;
  }

  @override
  State<PlayerGestureSurface> createState() => _PlayerGestureSurfaceState();
}

class _PlayerGestureSurfaceState extends State<PlayerGestureSurface> {
  Duration? _lastTapTime;
  Offset? _lastTapPosition;
  Duration _pointerTime = Duration.zero;
  bool _holding = false;

  void _clearTap() {
    _lastTapTime = null;
    _lastTapPosition = null;
  }

  void _tap(TapUpDetails details) {
    final elapsed = _lastTapTime == null ? null : _pointerTime - _lastTapTime!;
    final isDouble =
        elapsed != null &&
        elapsed >= kDoubleTapMinTime &&
        elapsed <= kDoubleTapTimeout &&
        (details.localPosition - _lastTapPosition!).distance <= kDoubleTapSlop;
    if (isDouble) {
      _clearTap();
      widget.onDoubleTap(details.localPosition);
    } else {
      _lastTapTime = _pointerTime;
      _lastTapPosition = details.localPosition;
      widget.onTap();
    }
  }

  void _endHold() {
    if (!_holding) return;
    _holding = false;
    widget.onHoldEnd();
  }

  @override
  Widget build(BuildContext context) => Listener(
    // Opaque prevents the native PlayerView from joining gesture arbitration.
    behavior: HitTestBehavior.opaque,
    onPointerDown: (event) {
      if (_holding) _endHold(); // A second finger cancels temporary speed.
      _pointerTime = event.timeStamp;
    },
    onPointerUp: (_) => _endHold(),
    onPointerCancel: (_) {
      _clearTap();
      _endHold();
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _tap,
      onLongPressStart: (_) {
        _clearTap();
        _holding = true;
        widget.onHoldStart();
      },
      onLongPressEnd: (_) => _endHold(),
      onLongPressCancel: _endHold,
      onScaleStart: (details) {
        _clearTap();
        _endHold();
        widget.onScaleStart(details);
      },
      onScaleUpdate: widget.onScaleUpdate,
      onScaleEnd: widget.onScaleEnd,
      child: const SizedBox.expand(),
    ),
  );
}

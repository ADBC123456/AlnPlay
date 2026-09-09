import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

/// Root navigation with a draggable refracting lens and a separate search.
class LiquidGlassDock extends StatefulWidget {
  const LiquidGlassDock({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onSearch,
    required this.labels,
    required this.searchLabel,
    this.searchActive = false,
  }) : assert(labels.length == 3),
       assert(selectedIndex >= 0 && selectedIndex < 3);

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onSearch;
  final List<String> labels;
  final String searchLabel;
  final bool searchActive;

  static const double maxWidth = 560;
  static double heightFor(TextScaler textScaler) =>
      (64 + math.max(0, textScaler.scale(12) - 12)).clamp(64, 84).toDouble();

  @override
  State<LiquidGlassDock> createState() => _LiquidGlassDockState();
}

class _LiquidGlassDockState extends State<LiquidGlassDock>
    with SingleTickerProviderStateMixin {
  static const _icons = [
    Icons.video_library_outlined,
    Icons.folder_outlined,
    Icons.person_outline_rounded,
  ];
  static const _selectedIcons = [
    Icons.video_library_rounded,
    Icons.folder_rounded,
    Icons.person_rounded,
  ];
  static Future<ui.FragmentProgram>? _program;

  final _atlasKey = GlobalKey();
  ui.Image? _atlas;
  Size? _atlasLogicalSize;
  ui.FragmentShader? _shader;
  late final AnimationController _settle;
  Animation<double>? _settleAnimation;
  double? _lensX;
  double? _dragStartX;
  double? _dragStartLensX;
  bool _dragging = false;
  bool _pressed = false;
  bool _captureQueued = false;
  int? _pendingExternalIndex;

  @override
  void initState() {
    super.initState();
    _settle =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          if (_settleAnimation != null) {
            setState(() => _lensX = _settleAnimation!.value);
          }
        });
    if (ui.ImageFilter.isShaderFilterSupported) _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = await (_program ??= ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass.frag',
      ));
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
      _queueCapture();
    } catch (_) {
      // Navigation remains functional with the plain selected glass pill.
    }
  }

  @override
  void didUpdateWidget(covariant LiquidGlassDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.labels != widget.labels) {
      _invalidateAtlas();
      _queueCapture();
      if (_dragging) _pendingExternalIndex = widget.selectedIndex;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _invalidateAtlas();
    _queueCapture();
  }

  void _invalidateAtlas() {
    final old = _atlas;
    _atlas = null;
    _atlasLogicalSize = null;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    _shader?.dispose();
    _atlas?.dispose();
    super.dispose();
  }

  /// Captures only the small, local icon/text layer when its content changes.
  /// It never snapshots the scrolling page and is not run for drag frames.
  void _queueCapture() {
    if (_captureQueued || _shader == null) return;
    _captureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _captureQueued = false;
      if (!mounted) return;
      final object = _atlasKey.currentContext?.findRenderObject();
      if (object is! RenderRepaintBoundary || object.debugNeedsPaint) {
        _queueCapture();
        return;
      }
      try {
        final image = await object.toImage(
          pixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        if (!mounted) {
          image.dispose();
          return;
        }
        final old = _atlas;
        setState(() {
          _atlas = image;
          _atlasLogicalSize = object.size;
        });
        old?.dispose();
      } catch (_) {
        // Widget tests and older renderers keep the non-refracting fallback.
      }
    });
  }

  void _animateTo(double target, bool reduceMotion) {
    _settle.stop();
    if (reduceMotion || _lensX == null) {
      setState(() => _lensX = target);
      return;
    }
    _settleAnimation = Tween<double>(
      begin: _lensX!,
      end: target,
    ).animate(CurvedAnimation(parent: _settle, curve: Curves.easeOutCubic));
    _settle.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final height = LiquidGlassDock.heightFor(media.textScaler);
    return Align(
      widthFactor: 1,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: LiquidGlassDock.maxWidth),
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              Expanded(
                child: _GlassSurface(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const inset = 5.0;
                      final usable = constraints.maxWidth - inset * 2;
                      final slot = usable / 3;
                      final selectedCenter =
                          inset + slot * (widget.selectedIndex + .5);
                      if (!_dragging &&
                          !_settle.isAnimating &&
                          (_lensX == null ||
                              (_lensX! - selectedCenter).abs() > .5)) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && !_dragging) {
                            _animateTo(selectedCenter, media.disableAnimations);
                          }
                        });
                      }
                      final center = (_lensX ?? selectedCenter).clamp(
                        inset + slot / 2,
                        constraints.maxWidth - inset - slot / 2,
                      );
                      final atlasReady =
                          _shader != null &&
                          _atlas != null &&
                          _atlasLogicalSize != null &&
                          (_atlasLogicalSize!.width - usable).abs() < .5 &&
                          (_atlasLogicalSize!.height -
                                      (constraints.maxHeight - inset * 2))
                                  .abs() <
                              .5;
                      return Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) {
                          _settle.stop();
                          setState(() {
                            _pressed = true;
                            _dragging = false;
                            _dragStartX = event.localPosition.dx;
                            _dragStartLensX = center;
                          });
                        },
                        onPointerMove: (event) {
                          final start = _dragStartX;
                          if (start == null) return;
                          final delta = event.localPosition.dx - start;
                          if (!_dragging && delta.abs() <= 8) return;
                          setState(() {
                            _dragging = true;
                            _lensX = (_dragStartLensX! + delta).clamp(
                              inset + slot / 2,
                              constraints.maxWidth - inset - slot / 2,
                            );
                          });
                        },
                        onPointerUp: (event) {
                          final wasDragging = _dragging;
                          setState(() {
                            _pressed = false;
                            _dragging = false;
                            _dragStartX = null;
                          });
                          // A normal tap is committed by InkWell so keyboard
                          // activation and focus semantics use the same path.
                          if (!wasDragging) return;
                          final hit = (((_lensX ?? center) - inset) / slot)
                              .floor()
                              .clamp(0, 2);
                          final target = _pendingExternalIndex ?? hit;
                          _pendingExternalIndex = null;
                          _animateTo(
                            inset + slot * (target + .5),
                            media.disableAnimations,
                          );
                          if (target != widget.selectedIndex) {
                            widget.onDestinationSelected(target);
                          }
                        },
                        onPointerCancel: (_) {
                          setState(() {
                            _pressed = false;
                            _dragging = false;
                            _dragStartX = null;
                          });
                          _animateTo(selectedCenter, media.disableAnimations);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(inset),
                          child: Stack(
                            children: [
                              if (!atlasReady)
                                _SelectionLens(
                                  left: center - inset - slot / 2,
                                  width: slot,
                                  height: height,
                                  colors: colors,
                                  pressed: _pressed,
                                ),
                              RepaintBoundary(
                                key: _atlasKey,
                                child: _DestinationRow(
                                  labels: widget.labels,
                                  selectedIndex: widget.selectedIndex,
                                  onSelected: widget.onDestinationSelected,
                                  icons: _icons,
                                  selectedIcons: _selectedIcons,
                                ),
                              ),
                              // Cover the undisplaced glyph inside the lens,
                              // then restore only its refracted atlas sample.
                              // This ordering prevents a doubled/ghost icon.
                              if (atlasReady)
                                _SelectionLens(
                                  left: center - inset - slot / 2,
                                  width: slot,
                                  height: height,
                                  colors: colors,
                                  pressed: _pressed,
                                ),
                              if (atlasReady)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: _LensPainter(
                                        shader: _shader!,
                                        atlas: _atlas!,
                                        lensCenter: center - inset,
                                        lensWidth: slot,
                                        pressed: _pressed,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox.square(
                dimension: 64,
                child: _GlassSurface(
                  child: Semantics(
                    button: true,
                    selected: widget.searchActive,
                    label: widget.searchLabel,
                    onTap: widget.onSearch,
                    child: ExcludeSemantics(
                      child: Tooltip(
                        message: widget.searchLabel,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: widget.onSearch,
                          child: ColoredBox(
                            color: widget.searchActive
                                ? colors.onSurface.withValues(alpha: .08)
                                : Colors.transparent,
                            child: Icon(
                              Icons.search_rounded,
                              size: 29,
                              color: colors.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionLens extends StatelessWidget {
  const _SelectionLens({
    required this.left,
    required this.width,
    required this.height,
    required this.colors,
    required this.pressed,
  });
  final double left;
  final double width;
  final double height;
  final ColorScheme colors;
  final bool pressed;

  @override
  Widget build(BuildContext context) => Positioned(
    left: left,
    top: 0,
    width: width,
    bottom: 0,
    child: DecoratedBox(
      key: const Key('dock-selection-lens'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(height),
        color: colors.surface.withValues(alpha: pressed ? .99 : .97),
        border: Border.all(
          color: colors.onSurface.withValues(alpha: pressed ? .15 : .09),
        ),
      ),
    ),
  );
}

class _DestinationRow extends StatelessWidget {
  const _DestinationRow({
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    required this.icons,
    required this.selectedIcons,
  });
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<IconData> icons;
  final List<IconData> selectedIcons;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: List.generate(3, (index) {
        final selected = index == selectedIndex;
        return Expanded(
          child: Semantics(
            selected: selected,
            button: true,
            label: labels[index],
            onTap: () => onSelected(index),
            child: ExcludeSemantics(
              child: Tooltip(
                message: labels[index],
                child: InkWell(
                  borderRadius: BorderRadius.circular(100),
                  overlayColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  splashFactory: NoSplash.splashFactory,
                  onTap: () => onSelected(index),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          selected ? selectedIcons[index] : icons[index],
                          size: 24,
                          color: selected
                              ? colors.onSurface
                              : colors.onSurfaceVariant,
                        ),
                        const SizedBox(height: 2),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Text(
                            labels[index],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textScaler: MediaQuery.textScalerOf(
                              context,
                            ).clamp(maxScaleFactor: 2),
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.15,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: selected
                                  ? colors.onSurface
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _LensPainter extends CustomPainter {
  const _LensPainter({
    required this.shader,
    required this.atlas,
    required this.lensCenter,
    required this.lensWidth,
    required this.pressed,
  });
  final ui.FragmentShader shader;
  final ui.Image atlas;
  final double lensCenter;
  final double lensWidth;
  final bool pressed;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, lensCenter)
      ..setFloat(3, size.height / 2)
      ..setFloat(4, lensWidth)
      ..setFloat(5, size.height)
      ..setFloat(6, pressed ? 1 : 0)
      ..setImageSampler(0, atlas);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _LensPainter oldDelegate) =>
      oldDelegate.atlas != atlas ||
      oldDelegate.lensCenter != lensCenter ||
      oldDelegate.lensWidth != lensWidth ||
      oldDelegate.pressed != pressed;
}

class _GlassSurface extends StatelessWidget {
  const _GlassSurface({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final radius = BorderRadius.circular(100);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .25 : .13),
            blurRadius: 22,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: 18,
            sigmaY: 18,
            tileMode: TileMode.clamp,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              color: (dark ? const Color(0xFF202024) : Colors.white).withValues(
                alpha: highContrast ? .96 : (dark ? .62 : .54),
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: dark ? .16 : .65),
                width: .8,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: .08),
                  Colors.white.withValues(alpha: 0),
                  Colors.white.withValues(alpha: dark ? .03 : .09),
                ],
              ),
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      ),
    );
  }
}

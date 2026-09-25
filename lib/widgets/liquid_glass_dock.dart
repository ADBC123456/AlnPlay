import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';

Size _lensScale(double position, double pressure, bool reduceMotion) => Size(
  1 +
      (.12 + .08 * LiquidGlassDock.elasticity) * pressure +
      (reduceMotion ? 0 : .04 * math.sin((position % 1) * math.pi).abs()),
  1 + (.22 + .14 * LiquidGlassDock.elasticity) * pressure,
);

/// Root navigation with a movable glass lens and a separate search action.
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

  /// Tuned to the public `liquid-glass-react` controls.  Keeping the values
  /// here makes the port auditable and prevents the shader and gesture code
  /// from drifting apart when the visual treatment is adjusted later.
  static const double displacementScale = 200;
  static const double blurAmount = 0;
  static const double saturation = 150;
  static const double aberrationIntensity = 9;
  static const double elasticity = .55;

  /// The dock shell has its own frosted backdrop.  `blurAmount` belongs to
  /// the moving lens, while this value is the Gaussian frosting behind it.
  static const double dockBackdropBlurSigma = 18;

  static const double maxWidth = 560;
  static double heightFor(TextScaler textScaler) =>
      (64 + math.max(0, textScaler.scale(12) - 12)).clamp(64, 84).toDouble();

  @override
  State<LiquidGlassDock> createState() => _LiquidGlassDockState();
}

class _LiquidGlassDockState extends State<LiquidGlassDock>
    with TickerProviderStateMixin, WidgetsBindingObserver {
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
  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    // Higher elasticity means a softer return.  .55 maps to a responsive
    // spring that still has a visible, short Q-bounce on release.
    stiffness: 420 * (1 - LiquidGlassDock.elasticity * .22),
    ratio: .85 - LiquidGlassDock.elasticity * .08,
  );

  // Slot coordinates survive window resizing without a pixel-position jump.
  late final _position = AnimationController.unbounded(
    vsync: this,
    value: widget.selectedIndex.toDouble(),
  );
  late final _pressure = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  );
  final _lightX = ValueNotifier<double>(.32);
  late final Listenable _motion = Listenable.merge([
    _position,
    _pressure,
    _lightX,
  ]);
  bool _dragging = false;
  bool _externalSelectionPending = false;
  bool _reduceMotion = false;
  int? _pointer;
  int? _settlingTarget;
  double _slotWidth = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _resetInteraction();
  }

  @override
  void didUpdateWidget(covariant LiquidGlassDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      if (_dragging) {
        _externalSelectionPending = true;
      } else {
        _settle(widget.selectedIndex);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _resetInteraction();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position.dispose();
    _pressure.dispose();
    _lightX.dispose();
    super.dispose();
  }

  void _settle(int target, {double velocity = 0}) {
    // A parent's selection acknowledgement must not erase release velocity.
    if (_position.isAnimating && _settlingTarget == target) return;
    _settlingTarget = target;
    _position.stop();
    if (_reduceMotion ||
        ((_position.value - target).abs() < .001 && velocity.abs() < .001)) {
      _position.value = target.toDouble();
      return;
    }
    _position.animateWith(
      SpringSimulation(
        _spring,
        _position.value,
        target.toDouble(),
        velocity.clamp(-12, 12),
        tolerance: const Tolerance(distance: .001, velocity: .001),
        snapToEnd: true,
      ),
    );
  }

  void _releasePressure() {
    if (_reduceMotion) {
      _pressure.value = 0;
    } else {
      _pressure.reverse();
    }
  }

  void _resetInteraction() {
    _pointer = null;
    _dragging = false;
    _externalSelectionPending = false;
    _settlingTarget = null;
    _pressure.value = 0;
    _lightX.value = .32;
    _position.value = widget.selectedIndex.toDouble();
  }

  void _cancelInteraction() {
    _pointer = null;
    _dragging = false;
    _externalSelectionPending = false;
    _releasePressure();
    _settle(widget.selectedIndex);
  }

  void _select(int index) {
    _settle(index);
    widget.onDestinationSelected(index);
  }

  void _endDrag(DragEndDetails details) {
    if (!_dragging) return;
    final velocity = details.velocity.pixelsPerSecond.dx * .9 / _slotWidth;
    final target = _externalSelectionPending
        ? widget.selectedIndex
        : (_position.value + (velocity * .06).clamp(-.45, .45)).round().clamp(
            0,
            2,
          );
    _dragging = false;
    _pointer = null;
    _externalSelectionPending = false;
    _releasePressure();
    _settle(target, velocity: velocity);
    if (target != widget.selectedIndex) {
      widget.onDestinationSelected(target);
    }
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
                  backdropClipper: _DockLensCutout(
                    position: _position,
                    pressure: _pressure,
                    motion: _motion,
                    reduceMotion: _reduceMotion,
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const inset = 5.0;
                      final slot = (constraints.maxWidth - inset * 2) / 3;
                      _slotWidth = slot;
                      return Listener(
                        onPointerDown: (event) {
                          if (_pointer != null) return;
                          _pointer = event.pointer;
                          _position.stop();
                          _lightX.value =
                              ((event.localPosition.dx - inset) / slot -
                                      _position.value)
                                  .clamp(0, 1);
                          if (!_reduceMotion) _pressure.forward();
                        },
                        onPointerMove: (event) {
                          if (_pointer != event.pointer || _reduceMotion) {
                            return;
                          }
                          _lightX.value =
                              ((event.localPosition.dx - inset) / slot -
                                      _position.value)
                                  .clamp(0, 1);
                        },
                        onPointerUp: (event) {
                          if (_pointer != event.pointer) return;
                          _pointer = null;
                          _releasePressure();
                        },
                        onPointerCancel: (event) {
                          if (_pointer == event.pointer) _cancelInteraction();
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          dragStartBehavior: DragStartBehavior.down,
                          onHorizontalDragStart: (_) {
                            _position.stop();
                            _dragging = true;
                          },
                          onHorizontalDragUpdate: (details) {
                            if (!_dragging) return;
                            _position.value =
                                (_position.value + details.delta.dx * .9 / slot)
                                    .clamp(0, 2);
                          },
                          onHorizontalDragEnd: _endDrag,
                          onHorizontalDragCancel: _cancelInteraction,
                          child: Padding(
                            padding: const EdgeInsets.all(inset),
                            child: Stack(
                              fit: StackFit.expand,
                              clipBehavior: Clip.none,
                              children: [
                                AnimatedBuilder(
                                  animation: _motion,
                                  builder: (context, _) {
                                    final pressure = _pressure.value;
                                    final scale = _lensScale(
                                      _position.value,
                                      pressure,
                                      _reduceMotion,
                                    );
                                    return Align(
                                      alignment: Alignment.centerLeft,
                                      child: Transform.translate(
                                        offset: Offset(
                                          _position.value.clamp(-.08, 2.08) *
                                              slot,
                                          0,
                                        ),
                                        child: Transform.scale(
                                          scaleX: scale.width,
                                          scaleY: scale.height,
                                          child: SizedBox(
                                            key: const Key(
                                              'dock-selection-lens',
                                            ),
                                            width: slot,
                                            height: height - inset * 2,
                                            child: _GlassSurface(
                                              lens: true,
                                              pressure: pressure,
                                              lightX: _lightX.value,
                                              child: const SizedBox.expand(),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                Row(
                                  children: List.generate(3, (index) {
                                    final selected =
                                        index == widget.selectedIndex;
                                    final color = selected
                                        ? colors.onSurface
                                        : colors.onSurfaceVariant;
                                    return Expanded(
                                      child: Semantics(
                                        selected: selected,
                                        button: true,
                                        label: widget.labels[index],
                                        onTap: () => _select(index),
                                        child: ExcludeSemantics(
                                          child: Tooltip(
                                            message: widget.labels[index],
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(100),
                                              splashFactory:
                                                  NoSplash.splashFactory,
                                              overlayColor:
                                                  WidgetStateProperty.resolveWith(
                                                    (states) =>
                                                        states.contains(
                                                          WidgetState.focused,
                                                        )
                                                        ? colors.onSurface
                                                              .withValues(
                                                                alpha: .12,
                                                              )
                                                        : Colors.transparent,
                                                  ),
                                              onTap: () => _select(index),
                                              child: AnimatedBuilder(
                                                animation: _motion,
                                                builder: (context, child) {
                                                  final delta =
                                                      index - _position.value;
                                                  final proximity =
                                                      (1 - delta.abs()).clamp(
                                                        0.0,
                                                        1.0,
                                                      );
                                                  final pressure =
                                                      _pressure.value *
                                                      proximity;
                                                  // Keep this function smooth
                                                  // through delta == 0. A
                                                  // sign based offset flips
                                                  // at the center and makes
                                                  // the label jump while the
                                                  // lens crosses it.
                                                  return Transform.translate(
                                                    offset: Offset(
                                                      delta * pressure * 5,
                                                      0,
                                                    ),
                                                    child: Transform.scale(
                                                      scale: 1 + pressure * .08,
                                                      child: child,
                                                    ),
                                                  );
                                                },
                                                child: Center(
                                                  child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        selected
                                                            ? _selectedIcons[index]
                                                            : _icons[index],
                                                        size: 24,
                                                        color: color,
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Padding(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 3,
                                                            ),
                                                        child: Text(
                                                          widget.labels[index],
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          textScaler: media
                                                              .textScaler
                                                              .clamp(
                                                                maxScaleFactor:
                                                                    2,
                                                              ),
                                                          style: TextStyle(
                                                            fontSize: 12,
                                                            height: 1.15,
                                                            fontWeight: selected
                                                                ? FontWeight
                                                                      .w600
                                                                : FontWeight
                                                                      .w400,
                                                            color: color,
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
                                      ),
                                    );
                                  }),
                                ),
                              ],
                            ),
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
                  circular: true,
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

/// Shader instances have separate uniforms; only their program is shared.
class _GlassSurface extends StatefulWidget {
  const _GlassSurface({
    required this.child,
    this.circular = false,
    this.lens = false,
    this.pressure = 0,
    this.lightX = .32,
    this.backdropClipper,
  });
  final Widget child;
  final bool circular;
  final bool lens;
  final double pressure;
  final double lightX;
  final CustomClipper<Path>? backdropClipper;

  @override
  State<_GlassSurface> createState() => _GlassSurfaceState();
}

class _GlassSurfaceState extends State<_GlassSurface> {
  static Future<ui.FragmentProgram>? _program;
  static final _lensBlur = ui.ImageFilter.blur(
    sigmaX: LiquidGlassDock.dockBackdropBlurSigma,
    sigmaY: LiquidGlassDock.dockBackdropBlurSigma,
    tileMode: TileMode.clamp,
  );
  static final _dockBlur = ui.ImageFilter.blur(
    sigmaX: LiquidGlassDock.dockBackdropBlurSigma,
    sigmaY: LiquidGlassDock.dockBackdropBlurSigma,
    tileMode: TileMode.clamp,
  );
  ui.FragmentShader? _shader;
  @override
  void initState() {
    super.initState();
    if (widget.lens && ui.ImageFilter.isShaderFilterSupported) {
      _loadShader();
    }
  }

  Future<void> _loadShader() async {
    try {
      final program = await (_program ??= ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass.frag',
      ));
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // Keep the blurred material fallback on unsupported renderers.
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final shader = _shader;
        final baseBlur = widget.lens ? _lensBlur : _dockBlur;
        final material = CustomPaint(
          painter: _GlassEdgePainter(
            dark: dark,
            highContrast: highContrast,
            circular: widget.circular,
            lens: widget.lens,
            pressure: widget.pressure,
            lightX: widget.lightX,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.lens
                  ? (dark
                        ? Colors.black.withValues(alpha: .62)
                        : Colors.white.withValues(alpha: .58))
                  : Colors.transparent,
            ),
            child: const SizedBox.expand(),
          ),
        );
        final filtered = widget.lens && (shader == null || highContrast)
            ? material
            : shader != null && !highContrast
            ? _GlassBackdrop(
                shader: shader,
                baseBlur: baseBlur,
                viewport: MediaQuery.sizeOf(context),
                displacementScale: LiquidGlassDock.displacementScale,
                aberrationIntensity: LiquidGlassDock.aberrationIntensity,
                saturation: LiquidGlassDock.saturation,
                elasticity: LiquidGlassDock.elasticity,
                pressure: widget.pressure,
                child: material,
              )
            : BackdropFilter(
                filter: baseBlur,
                enabled: !highContrast,
                child: material,
              );
        final clipped = widget.backdropClipper != null && !highContrast
            ? ClipPath(clipper: widget.backdropClipper, child: filtered)
            : filtered;
        final background = DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size.height / 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: widget.lens
                      ? .08 + widget.pressure * .08
                      : (dark ? .20 : .10),
                ),
                blurRadius: widget.lens ? 10 + widget.pressure * 8 : 18,
                offset: Offset(0, widget.lens ? 2 + widget.pressure * 3 : 6),
              ),
            ],
          ),
          child: widget.circular
              ? ClipOval(child: clipped)
              : ClipRSuperellipse(
                  borderRadius: BorderRadius.circular(size.height / 2),
                  child: clipped,
                ),
        );
        // Only the material is clipped. The active lens can grow beyond the
        // dock without changing any button's layout or touch target.
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            background,
            Material(type: MaterialType.transparency, child: widget.child),
          ],
        );
      },
    );
  }
}

/// Keep frosting around the lens, allowing its inward samples to see the page
/// rather than refracting an already heavily blurred intermediate surface.
class _DockLensCutout extends CustomClipper<Path> {
  _DockLensCutout({
    required this.position,
    required this.pressure,
    required Listenable motion,
    required this.reduceMotion,
  }) : super(reclip: motion);
  final Animation<double> position;
  final Animation<double> pressure;
  final bool reduceMotion;

  @override
  Path getClip(Size size) {
    const inset = 5.0;
    final slot = (size.width - inset * 2) / 3;
    final height = size.height - inset * 2;
    final scale = _lensScale(position.value, pressure.value, reduceMotion);
    final lens = Path()
      ..addRSuperellipse(
        ui.RSuperellipse.fromRectAndRadius(
          Rect.fromLTWH(0, 0, slot, height),
          Radius.circular(height / 2),
        ),
      );
    final transform = Matrix4.diagonal3Values(scale.width, scale.height, 1)
      ..setTranslationRaw(
        inset +
            position.value.clamp(-.08, 2.08) * slot +
            slot * (1 - scale.width) / 2,
        inset + height * (1 - scale.height) / 2,
        0,
      );
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPath(lens.transform(transform.storage), Offset.zero);
  }

  @override
  bool shouldReclip(covariant _DockLensCutout oldClipper) =>
      oldClipper.position != position ||
      oldClipper.pressure != pressure ||
      oldClipper.reduceMotion != reduceMotion;
}

/// Runtime backdrop filters sample the scene texture, not a widget-sized image.
/// Resolve the glass's screen rect during paint, after drag transforms/layout.
class _GlassBackdrop extends SingleChildRenderObjectWidget {
  const _GlassBackdrop({
    required this.shader,
    required this.baseBlur,
    required this.viewport,
    required this.displacementScale,
    required this.aberrationIntensity,
    required this.saturation,
    required this.elasticity,
    required this.pressure,
    required super.child,
  });
  final ui.FragmentShader shader;
  final ui.ImageFilter baseBlur;
  final Size viewport;
  final double displacementScale;
  final double aberrationIntensity;
  final double saturation;
  final double elasticity;
  final double pressure;

  @override
  _RenderGlassBackdrop createRenderObject(BuildContext context) =>
      _RenderGlassBackdrop(this);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderGlassBackdrop renderObject,
  ) {
    renderObject.configuration = this;
    renderObject.markNeedsPaint();
  }
}

class _RenderGlassBackdrop extends RenderProxyBox {
  _RenderGlassBackdrop(this.configuration);
  _GlassBackdrop configuration;
  final _backdropLayer = LayerHandle<BackdropFilterLayer>();

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final rect = MatrixUtils.transformRect(
      getTransformTo(null),
      Offset.zero & size,
    );
    final config = configuration;
    config.shader
      ..setFloat(2, rect.width)
      ..setFloat(3, rect.height)
      // The React version expresses these as CSS/SVG pixels.  The Flutter
      // shader receives the same public values and converts them to a
      // viewport-normalized offset at the final sampling step.
      ..setFloat(4, config.displacementScale)
      ..setFloat(5, config.aberrationIntensity)
      ..setFloat(6, rect.left)
      ..setFloat(7, rect.top)
      ..setFloat(8, config.viewport.width)
      ..setFloat(9, config.viewport.height)
      ..setFloat(10, config.saturation)
      ..setFloat(11, config.elasticity)
      ..setFloat(12, config.pressure);
    final layer = _backdropLayer.layer ??= BackdropFilterLayer();
    layer.filter = ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(config.shader),
      inner: config.baseBlur,
    );
    context.pushLayer(layer, super.paint, offset);
  }

  @override
  void dispose() {
    _backdropLayer.layer = null;
    super.dispose();
  }
}

class _GlassEdgePainter extends CustomPainter {
  const _GlassEdgePainter({
    required this.dark,
    required this.highContrast,
    this.lens = false,
    this.pressure = 0,
    this.circular = false,
    this.lightX = .32,
  });
  final bool dark;
  final bool highContrast;
  final bool lens;
  final double pressure;
  final bool circular;
  final double lightX;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(.6);
    final path = Path();
    if (circular) {
      path.addOval(rect);
    } else {
      path.addRSuperellipse(
        ui.RSuperellipse.fromRectAndRadius(
          rect,
          Radius.circular(rect.height / 2),
        ),
      );
    }
    final tint = highContrast && !lens
        ? (dark ? const Color(0xFF252528) : const Color(0xFFF4F4F6))
        : lens
        ? Colors.white.withValues(alpha: dark ? .06 : .14)
        : (dark ? const Color(0xFF171719) : Colors.white).withValues(
            alpha: dark ? .18 : .12,
          );
    canvas.drawPath(path, Paint()..color = tint);
    if (lens) {
      canvas.save();
      canvas.clipPath(path);
      canvas.drawPath(
        path.shift(const Offset(0, -.8)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = Colors.black.withValues(alpha: .10 + pressure * .04),
      );
      canvas.restore();
    }
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: (lens ? .13 : .10) + pressure * .07),
            Colors.white.withValues(alpha: .015),
            Colors.white.withValues(alpha: lens ? .04 : .025),
          ],
          stops: const [0, .55, 1],
        ).createShader(rect),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = (dark ? Colors.white : Colors.black).withValues(
          alpha: highContrast ? .5 : (lens ? .11 : .22),
        ),
    );
    // Fade the curved reflection at both ends, rather than drawing a white rule.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height * .52));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: .5 + pressure * .15),
            Colors.white.withValues(alpha: .22),
            Colors.white.withValues(alpha: 0),
          ],
          stops: [0, lightX.clamp(.15, .7), (lightX + .3).clamp(.45, .95), 1],
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlassEdgePainter oldDelegate) =>
      oldDelegate.dark != dark ||
      oldDelegate.highContrast != highContrast ||
      oldDelegate.lens != lens ||
      oldDelegate.pressure != pressure ||
      oldDelegate.lightX != lightX ||
      oldDelegate.circular != circular;
}

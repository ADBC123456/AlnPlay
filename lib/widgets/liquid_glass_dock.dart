import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Root navigation, with a separate search action. The shell supplies the
/// exterior padding and bottom safe area, so this also fits iPad split windows.
class LiquidGlassDock extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final height = heightFor(MediaQuery.textScalerOf(context));
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return Align(
      widthFactor: 1,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              Expanded(
                child: _GlassSurface(
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: AnimatedAlign(
                            duration: duration,
                            curve: Curves.easeOutCubic,
                            alignment: AlignmentDirectional(
                              selectedIndex - 1.0,
                              0,
                            ),
                            child: FractionallySizedBox(
                              widthFactor: 1 / 3,
                              heightFactor: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(height),
                                  color: colors.onSurface.withValues(
                                    alpha: 0.08,
                                  ),
                                  border: Border.all(
                                    color: colors.onSurface.withValues(
                                      alpha: 0.07,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Row(
                          children: List.generate(3, (index) {
                            final selected = index == selectedIndex;
                            return Expanded(
                              child: Semantics(
                                selected: selected,
                                button: true,
                                label: labels[index],
                                onTap: () => onDestinationSelected(index),
                                child: ExcludeSemantics(
                                  child: Tooltip(
                                    message: labels[index],
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(
                                        height,
                                      ),
                                      onTap: () => onDestinationSelected(index),
                                      child: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              selected
                                                  ? _selectedIcons[index]
                                                  : _icons[index],
                                              size: 24,
                                              color: selected
                                                  ? colors.onSurface
                                                  : colors.onSurfaceVariant,
                                            ),
                                            const SizedBox(height: 2),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 3,
                                                  ),
                                              child: Text(
                                                labels[index],
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                // Keep labels contained at extreme
                                                // accessibility sizes; the full
                                                // name remains in semantics.
                                                textScaler:
                                                    MediaQuery.textScalerOf(
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
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox.square(
                dimension: 64,
                child: _GlassSurface(
                  child: Semantics(
                    button: true,
                    selected: searchActive,
                    label: searchLabel,
                    onTap: onSearch,
                    child: ExcludeSemantics(
                      child: Tooltip(
                        message: searchLabel,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onSearch,
                          child: ColoredBox(
                            color: searchActive
                                ? colors.onSurface.withValues(alpha: 0.08)
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

/// A locally clipped, live backdrop. Impeller supplies its input directly to
/// the lens shader; no widget snapshots, platform video capture, or idle ticker.
class _GlassSurface extends StatefulWidget {
  const _GlassSurface({required this.child});

  final Widget child;

  @override
  State<_GlassSurface> createState() => _GlassSurfaceState();
}

class _GlassSurfaceState extends State<_GlassSurface> {
  static Future<ui.FragmentProgram>? _program;
  ui.FragmentShader? _shader;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    if (ui.ImageFilter.isShaderFilterSupported) _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = await (_program ??= ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass.frag',
      ));
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // Older renderers and shader asset failures retain a functional frosted
      // material. A failed load must never prevent root navigation.
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final shader = _shader;
    // A shader ImageFilter receives the size of the whole bound backdrop as
    // its first vec2. That is commonly much larger than this clipped widget,
    // so the fragment shader must never derive a lens radius or centre from
    // that value. Start with a real Gaussian blur for predictable Android and
    // iOS glass, then let the shader add only a few pixels of local diffusion.
    final blur = ui.ImageFilter.blur(
      sigmaX: _pressed ? 16 : 18,
      sigmaY: _pressed ? 16 : 18,
      tileMode: TileMode.clamp,
    );
    ui.ImageFilter filter = blur;
    if (shader != null && ui.ImageFilter.isShaderFilterSupported) {
      // Floats 0 / 1 and sampler 0 are reserved for ImageFilter's engine
      // input. uPressed is therefore float 2.
      shader.setFloat(2, _pressed ? 1 : 0);
      filter = ui.ImageFilter.compose(
        outer: ui.ImageFilter.shader(shader),
        inner: blur,
      );
    }
    final radius = BorderRadius.circular(100);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.25 : 0.13),
            blurRadius: 22,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: filter,
          child: Listener(
            onPointerDown: (_) => _setPressed(true),
            onPointerUp: (_) => _setPressed(false),
            onPointerCancel: (_) => _setPressed(false),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                color: (dark ? const Color(0xFF202024) : Colors.white)
                    .withValues(
                      alpha: highContrast ? 0.96 : (dark ? 0.62 : 0.54),
                    ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: dark ? 0.16 : 0.65),
                  width: 0.8,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: _pressed ? 0.16 : 0.08),
                    Colors.white.withValues(alpha: 0),
                    Colors.white.withValues(alpha: dark ? 0.03 : 0.09),
                  ],
                ),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

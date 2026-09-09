import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Lightweight controls above the native video surface. The middle of the
/// screen stays empty so video gestures never compete with transport buttons.
class PlayerChrome extends StatelessWidget {
  const PlayerChrome({
    super.key,
    required this.visible,
    required this.title,
    required this.badges,
    required this.timeline,
    required this.playing,
    required this.completed,
    required this.locked,
    required this.danmakuVisible,
    required this.fullscreen,
    required this.isTv,
    required this.speed,
    required this.resolution,
    required this.playFocusNode,
    required this.onFocus,
    required this.onBack,
    required this.onPlay,
    required this.onNext,
    required this.onDanmaku,
    required this.onDanmakuSettings,
    required this.onSubtitles,
    required this.onEpisodes,
    required this.onSpeed,
    required this.onInfo,
    required this.onAudio,
    required this.onMore,
    required this.onLock,
    required this.onFullscreen,
    required this.onRewind,
    required this.onForward,
    this.subtitlesEnabled = false,
  });

  static const accent = Color(0xFFFB7299);
  final bool subtitlesEnabled;
  final bool visible,
      playing,
      completed,
      locked,
      danmakuVisible,
      fullscreen,
      isTv;
  final String title, speed, resolution;
  final List<Widget> badges;
  final Widget timeline;
  final FocusNode playFocusNode;
  final VoidCallback onFocus,
      onBack,
      onDanmaku,
      onDanmakuSettings,
      onSubtitles,
      onEpisodes,
      onSpeed,
      onInfo,
      onAudio,
      onMore,
      onLock,
      onFullscreen,
      onRewind,
      onForward;
  final VoidCallback? onPlay, onNext;

  Widget _icon(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback? action, {
    bool active = false,
    FocusNode? focusNode,
    double size = 28,
    bool allowLocked = false,
  }) => Focus(
    canRequestFocus: false,
    onFocusChange: (focused) {
      if (focused) onFocus();
    },
    child: IconButton(
      tooltip: context.tr(label),
      focusNode: focusNode,
      autofocus: isTv && focusNode != null,
      onPressed: locked && !allowLocked ? null : action,
      icon: Icon(icon, size: size),
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: active ? accent : Colors.white,
        disabledForegroundColor: Colors.white30,
      ),
    ),
  );

  Widget _text(
    BuildContext context,
    String label,
    VoidCallback action, {
    bool active = false,
  }) => TextButton(
    onPressed: locked ? null : action,
    onFocusChange: (focused) {
      if (focused) onFocus();
    },
    style: TextButton.styleFrom(
      foregroundColor: active ? accent : Colors.white,
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    child: AppText(label),
  );

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    Widget fade(Widget child) => IgnorePointer(
      ignoring: !visible,
      child: ExcludeFocus(
        excluding: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: duration,
          child: RepaintBoundary(child: child),
        ),
      ),
    );
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: fade(
            _PlayerBarBackground(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xB8000000), Colors.transparent],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          _icon(
                            context,
                            'Back',
                            Icons.arrow_back_ios_new,
                            onBack,
                            allowLocked: true,
                          ),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          _icon(
                            context,
                            'Audio tracks',
                            Icons.graphic_eq,
                            onAudio,
                          ),
                          _icon(context, 'More', Icons.more_vert, onMore),
                        ],
                      ),
                      if (badges.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final badge in badges)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: badge,
                                  ),
                              ],
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
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: fade(
            ConstrainedBox(
              // Bound the complete interactive bar, including SafeArea and
              // padding. Its hit-test region therefore never reaches the
              // screen midpoint, which remains a real video gesture zone.
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .45,
              ),
              child: _PlayerBarBackground(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Color(0x66000000),
                      Color(0xCC000000),
                    ],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 24, 12, 4),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IgnorePointer(
                            ignoring: locked,
                            child: ExcludeFocus(
                              excluding: locked,
                              child: timeline,
                            ),
                          ),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final transport = Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _icon(
                                    context,
                                    completed
                                        ? 'Replay'
                                        : playing
                                        ? 'Pause'
                                        : 'Play',
                                    completed
                                        ? Icons.replay
                                        : playing
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    onPlay,
                                    focusNode: playFocusNode,
                                    size: 36,
                                  ),
                                  if (isTv)
                                    _icon(
                                      context,
                                      'Rewind 10 seconds',
                                      Icons.replay_10,
                                      onRewind,
                                    ),
                                  _icon(
                                    context,
                                    'Next episode',
                                    Icons.skip_next,
                                    onNext,
                                  ),
                                  if (isTv)
                                    _icon(
                                      context,
                                      'Forward 10 seconds',
                                      Icons.forward_10,
                                      onForward,
                                    ),
                                  _icon(
                                    context,
                                    danmakuVisible
                                        ? 'Hide danmaku'
                                        : 'Show danmaku',
                                    danmakuVisible
                                        ? Icons.subtitles
                                        : Icons.subtitles_off,
                                    onDanmaku,
                                    active: danmakuVisible,
                                  ),
                                  _icon(
                                    context,
                                    'Danmaku settings',
                                    Icons.tune,
                                    onDanmakuSettings,
                                  ),
                                ],
                              );
                              final actions = Wrap(
                                alignment: WrapAlignment.end,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  _text(
                                    context,
                                    'Subtitles',
                                    onSubtitles,
                                    active: subtitlesEnabled,
                                  ),
                                  _text(context, 'Select episode', onEpisodes),
                                  _text(context, speed, onSpeed),
                                  _text(context, resolution, onInfo),
                                  if (!isTv)
                                    _icon(
                                      context,
                                      'Fullscreen',
                                      fullscreen
                                          ? Icons.fullscreen_exit
                                          : Icons.fullscreen,
                                      onFullscreen,
                                    ),
                                ],
                              );
                              final scale =
                                  MediaQuery.textScalerOf(context).scale(16) /
                                  16;
                              if (constraints.maxWidth >=
                                  (isTv ? 850 : 650) * scale) {
                                return Row(
                                  children: [
                                    transport,
                                    Expanded(child: actions),
                                  ],
                                );
                              }
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                // The scroll view is reversed so its bottom
                                // stays visible. Keep primary transport there
                                // and let secondary actions scroll above it.
                                children: [actions, transport],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (!isTv)
          Positioned(
            right: 12,
            top: 0,
            bottom: 0,
            child: Center(
              child: fade(
                SafeArea(
                  left: false,
                  child: _icon(
                    context,
                    locked ? 'Unlock' : 'Lock',
                    locked ? Icons.lock : Icons.lock_open,
                    onLock,
                    active: locked,
                    allowLocked: true,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// A gradient is decoration, not a touch target. Empty padding around the
// controls must continue to pass taps and holds through to the video.
class _PlayerBarBackground extends StatelessWidget {
  const _PlayerBarBackground({required this.decoration, required this.child});
  final Decoration decoration;
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: IgnorePointer(child: DecoratedBox(decoration: decoration)),
      ),
      child,
    ],
  );
}

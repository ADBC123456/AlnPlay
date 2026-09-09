import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Shared visual tokens for player-side workflows (subtitles, episodes and
/// danmaku). The panel deliberately does not blur or capture the video layer.
abstract final class PlayerSidePanelTokens {
  static const accent = Color(0xFFFB7299);
  static const panel = Color(0xD21B1B20);
  static const surface = Color(0x9E2B2B31);
  static const selectedSurface = Color(0x3DFB7299);
  static const border = Color(0x24FFFFFF);
  static const text = Colors.white;
  static const textMuted = Color(0xB3FFFFFF);
  static const barrier = Color(0x73000000);
  static const radius = 18.0;
  static const contentPadding = EdgeInsets.fromLTRB(20, 8, 20, 20);
  static const shadow = BoxShadow(
    color: Color(0x52000000),
    blurRadius: 24,
    offset: Offset(-8, 0),
  );
}

/// Opens an edge-anchored player workflow without sampling the native HDR
/// surface. System back and tapping the scrim both dismiss the route.
Future<T?> showPlayerSidePanel<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
}) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: PlayerSidePanelTokens.barrier,
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 220),
    pageBuilder: (routeContext, _, _) =>
        _PlayerSidePanelFrame(title: title, child: builder(routeContext)),
    transitionBuilder: (_, animation, secondaryAnimation, child) {
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: child,
      );
    },
  );
}

class _PlayerSidePanelFrame extends StatelessWidget {
  const _PlayerSidePanelFrame({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final tablet = size.shortestSide >= 600;
    final width = tablet
        ? math.min(size.width * .58, 560.0)
        : size.width > size.height
        ? math.min(size.width * .48, 420.0)
        : math.min(size.width * .90, 420.0);
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        key: const Key('player-side-panel'),
        width: width,
        height: double.infinity,
        child: Theme(
          data: ThemeData.dark(useMaterial3: true),
          child: Material(
            color: PlayerSidePanelTokens.panel,
            elevation: 0,
            shadowColor: Colors.transparent,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: PlayerSidePanelTokens.border),
                ),
                boxShadow: [PlayerSidePanelTokens.shadow],
              ),
              child: SafeArea(
                left: false,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: AppText(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: PlayerSidePanelTokens.text,
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            key: const Key('player-side-panel-close'),
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).closeButtonTooltip,
                            onPressed: () => Navigator.of(context).pop(),
                            color: PlayerSidePanelTokens.text,
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: PlayerSidePanelTokens.border,
                    ),
                    Expanded(child: child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/player_network_speed.dart';

/// Loading feedback above the native HDR surface, never a capture of the video.
/// No percentage is inferred from buffer duration: live streams and adaptive
/// backends have no fixed initial-buffer target exposed to the UI.
class PlayerLoadingOverlay extends StatefulWidget {
  const PlayerLoadingOverlay({
    super.key,
    required this.videoLoading,
    required this.preparingVideo,
    required this.bufferedAhead,
    this.danmakuLabel,
    this.danmakuLoading = false,
    this.danmakuProgress,
    this.danmakuBytesPerSecond,
  });

  final bool videoLoading;
  final bool preparingVideo;
  final Duration bufferedAhead;
  final String? danmakuLabel;
  final bool danmakuLoading;
  final double? danmakuProgress;
  final double? danmakuBytesPerSecond;

  static String formatRate(double bytesPerSecond) {
    if (!bytesPerSecond.isFinite || bytesPerSecond < 0) return '—';
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MiB/s';
    }
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KiB/s';
  }

  @override
  State<PlayerLoadingOverlay> createState() => _PlayerLoadingOverlayState();
}

class _PlayerLoadingOverlayState extends State<PlayerLoadingOverlay>
    with WidgetsBindingObserver {
  final _network = PlayerNetworkSpeedTelemetry();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _network.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _network.start();
    } else {
      _network.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _network.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zh = AppLocalizations.of(context).isChinese;
    final seconds = (widget.bufferedAhead.inMilliseconds / 1000)
        .clamp(0, double.infinity)
        .toStringAsFixed(1);
    final progress = widget.danmakuProgress;
    return IgnorePointer(
      child: SafeArea(
        child: Padding(
          // Leave room for the top transport bar when only comments load.
          padding: EdgeInsets.fromLTRB(
            20,
            widget.videoLoading ? 12 : 80,
            20,
            12,
          ),
          child: Align(
            alignment: widget.videoLoading
                ? Alignment.center
                : Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: SingleChildScrollView(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xCC151519),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: DefaultTextStyle(
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      textAlign: TextAlign.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (widget.videoLoading) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    widget.preparingVideo
                                        ? (zh ? '正在准备视频…' : 'Preparing video…')
                                        : (zh ? '视频缓冲中…' : 'Buffering video…'),
                                  ),
                                ),
                              ],
                            ),
                            if (!widget.preparingVideo) ...[
                              const SizedBox(height: 8),
                              Text(
                                zh
                                    ? '已向前缓冲 $seconds 秒'
                                    : '$seconds s buffered ahead',
                              ),
                            ],
                          ],
                          if (widget.danmakuLabel != null) ...[
                            if (widget.videoLoading) const SizedBox(height: 12),
                            Text(widget.danmakuLabel!),
                            if (widget.danmakuLoading) ...[
                              const SizedBox(height: 8),
                              LinearProgressIndicator(
                                value: progress?.clamp(0, 1),
                                minHeight: 3,
                                color: Colors.white,
                                backgroundColor: Colors.white24,
                              ),
                            ],
                          ],
                          const SizedBox(height: 10),
                          ValueListenableBuilder<double?>(
                            valueListenable: _network.bytesPerSecond,
                            builder: (context, rate, _) {
                              final fallback = widget.danmakuBytesPerSecond;
                              final label = rate != null
                                  ? '${zh ? '本应用接收' : 'App download'} · ${PlayerLoadingOverlay.formatRate(rate)}'
                                  : fallback != null
                                  ? '${zh ? '弹幕平均下载' : 'Comments average'} · ${PlayerLoadingOverlay.formatRate(fallback)}'
                                  : (zh
                                        ? '网速 · —（等待采样或不可用）'
                                        : 'Speed · — (waiting / unavailable)');
                              return Text(
                                label,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
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
      ),
    );
  }
}

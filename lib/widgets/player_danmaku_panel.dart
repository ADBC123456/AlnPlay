import 'package:flutter/material.dart';

import '../danmaku/settings/danmaku_display_settings.dart';
import '../l10n/app_localizations.dart';
import 'player_side_panel.dart';

class PlayerDanmakuPanel extends StatefulWidget {
  const PlayerDanmakuPanel({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final DanmakuDisplaySettings settings;
  final ValueChanged<DanmakuDisplaySettings> onChanged;

  @override
  State<PlayerDanmakuPanel> createState() => _PlayerDanmakuPanelState();
}

class _PlayerDanmakuPanelState extends State<PlayerDanmakuPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const Key('player-danmaku-panel'),
      padding: PlayerSidePanelTokens.contentPadding,
      children: [
        _PanelCard(
          child: Column(
            children: [
              _settingSlider(
                key: const Key('danmaku-display-area'),
                label: 'Display area',
                value: widget.settings.displayArea.clamp(.25, 1),
                min: .25,
                max: 1,
                valueLabel: '${(widget.settings.displayArea * 100).round()}%',
                onChanged: (value) => widget.onChanged(
                  widget.settings.copyWith(displayArea: value),
                ),
              ),
              _settingSlider(
                key: const Key('danmaku-opacity'),
                label: 'Opacity',
                value: widget.settings.opacity.clamp(.1, 1),
                min: .1,
                max: 1,
                valueLabel: '${(widget.settings.opacity * 100).round()}%',
                onChanged: (value) =>
                    widget.onChanged(widget.settings.copyWith(opacity: value)),
              ),
              if (_expanded) ...[
                _settingSlider(
                  key: const Key('danmaku-font-size'),
                  label: 'Font size',
                  value: widget.settings.fontSize.clamp(12, 48),
                  min: 12,
                  max: 48,
                  divisions: 36,
                  valueLabel: widget.settings.fontSize.round().toString(),
                  onChanged: (value) => widget.onChanged(
                    widget.settings.copyWith(fontSize: value),
                  ),
                ),
                _settingSlider(
                  key: const Key('danmaku-scroll-speed'),
                  label: 'Scroll speed',
                  value: widget.settings.scrollSpeed.clamp(.5, 2),
                  min: .5,
                  max: 2,
                  valueLabel:
                      '${widget.settings.scrollSpeed.toStringAsFixed(1)}×',
                  onChanged: (value) => widget.onChanged(
                    widget.settings.copyWith(scrollSpeed: value),
                  ),
                ),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('danmaku-more-toggle'),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                  ),
                  label: AppText(_expanded ? 'Show less' : 'Show more'),
                  style: TextButton.styleFrom(
                    foregroundColor: PlayerSidePanelTokens.accent,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _PanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppText(
                'Danmaku type',
                style: TextStyle(
                  color: PlayerSidePanelTokens.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _typeChip(
                    key: const Key('danmaku-type-top'),
                    label: 'Top',
                    selected: widget.settings.showTop,
                    onSelected: (value) => widget.onChanged(
                      widget.settings.copyWith(showTop: value),
                    ),
                  ),
                  _typeChip(
                    key: const Key('danmaku-type-bottom'),
                    label: 'Bottom',
                    selected: widget.settings.showBottom,
                    onSelected: (value) => widget.onChanged(
                      widget.settings.copyWith(showBottom: value),
                    ),
                  ),
                  _typeChip(
                    key: const Key('danmaku-type-scroll'),
                    label: 'Scrolling',
                    selected: widget.settings.showScroll,
                    onSelected: (value) => widget.onChanged(
                      widget.settings.copyWith(showScroll: value),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _settingSlider({
    required Key key,
    required String label,
    required double value,
    required double min,
    required double max,
    required String valueLabel,
    required ValueChanged<double> onChanged,
    int? divisions,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AppText(
                  label,
                  style: const TextStyle(color: PlayerSidePanelTokens.text),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                valueLabel,
                style: const TextStyle(color: PlayerSidePanelTokens.textMuted),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: PlayerSidePanelTokens.accent,
              thumbColor: PlayerSidePanelTokens.accent,
              overlayColor: PlayerSidePanelTokens.accent.withValues(alpha: .16),
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: valueLabel,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeChip({
    required Key key,
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return FilterChip(
      key: key,
      label: AppText(label),
      selected: selected,
      onSelected: onSelected,
      showCheckmark: false,
      backgroundColor: Colors.white.withValues(alpha: .06),
      selectedColor: PlayerSidePanelTokens.selectedSurface,
      side: BorderSide(
        color: selected
            ? PlayerSidePanelTokens.accent
            : PlayerSidePanelTokens.border,
      ),
      labelStyle: TextStyle(
        color: selected
            ? PlayerSidePanelTokens.accent
            : PlayerSidePanelTokens.textMuted,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    );
  }
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: PlayerSidePanelTokens.surface,
      borderRadius: BorderRadius.circular(PlayerSidePanelTokens.radius),
      border: Border.all(color: PlayerSidePanelTokens.border),
    ),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

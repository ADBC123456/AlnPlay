import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'player_side_panel.dart';

class PlayerEpisodePanelItem<T> {
  const PlayerEpisodePanelItem({
    required this.value,
    required this.id,
    required this.label,
    this.number,
    this.season,
    this.subtitle,
    this.available = true,
  });

  final T value;
  final String id;
  final String label;
  final int? number;
  final int? season;
  final String? subtitle;
  final bool available;
}

/// Episode chooser shared by the player and any future playback surface.
/// Grouping uses real episode numbers; unavailable/missing entries keep their
/// place and never cause later episodes to be renumbered.
class PlayerEpisodePanel<T> extends StatefulWidget {
  const PlayerEpisodePanel({
    super.key,
    required this.items,
    required this.onSelected,
    this.currentId,
  });

  final List<PlayerEpisodePanelItem<T>> items;
  final String? currentId;
  final ValueChanged<PlayerEpisodePanelItem<T>> onSelected;

  @override
  State<PlayerEpisodePanel<T>> createState() => _PlayerEpisodePanelState<T>();
}

class _PlayerEpisodePanelState<T> extends State<PlayerEpisodePanel<T>> {
  int? _season;
  int _rangeIndex = 0;
  ScrollController? _gridController;
  String? _gridScope;

  PlayerEpisodePanelItem<T>? get _current {
    for (final item in widget.items) {
      if (item.id == widget.currentId) return item;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _selectInitialScope();
  }

  @override
  void didUpdateWidget(covariant PlayerEpisodePanel<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentId != widget.currentId ||
        oldWidget.items != widget.items) {
      _selectInitialScope();
    }
  }

  void _selectInitialScope() {
    final current = _current;
    _season = current?.season ?? widget.items.firstOrNull?.season;
    final ranges = _rangesFor(_itemsForSeason(_season));
    _rangeIndex = ranges.indexWhere(
      (range) => range.items.any((item) => item.id == widget.currentId),
    );
    if (_rangeIndex < 0) _rangeIndex = 0;
    _resetGrid();
  }

  void _resetGrid() {
    final old = _gridController;
    _gridController = null;
    _gridScope = null;
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void dispose() {
    _gridController?.dispose();
    super.dispose();
  }

  List<PlayerEpisodePanelItem<T>> _itemsForSeason(int? season) =>
      widget.items.where((item) => item.season == season).toList();

  List<_EpisodeRange<T>> _rangesFor(List<PlayerEpisodePanelItem<T>> items) {
    final numbered = <int, List<PlayerEpisodePanelItem<T>>>{};
    final unknown = <PlayerEpisodePanelItem<T>>[];
    for (final item in items) {
      final number = item.number;
      if (number == null || number <= 0) {
        unknown.add(item);
      } else {
        numbered.putIfAbsent((number - 1) ~/ 50, () => []).add(item);
      }
    }
    final keys = numbered.keys.toList()..sort();
    final maxNumber = numbered.values
        .expand((items) => items)
        .map((item) => item.number!)
        .fold<int>(0, (maximum, number) => number > maximum ? number : maximum);
    final ranges = [
      for (final key in keys)
        _EpisodeRange<T>(
          label: '${key * 50 + 1}–${(key * 50 + 50).clamp(1, maxNumber)}',
          items: numbered[key]!..sort(_compareItems),
        ),
    ];
    if (unknown.isNotEmpty) {
      ranges.add(_EpisodeRange(label: 'unknown', items: unknown));
    }
    return ranges;
  }

  int _compareItems(PlayerEpisodePanelItem<T> a, PlayerEpisodePanelItem<T> b) =>
      (a.number ?? 1 << 30).compareTo(b.number ?? 1 << 30);

  @override
  Widget build(BuildContext context) {
    final zh = AppLocalizations.of(context).isChinese;
    final seasons = widget.items.map((item) => item.season).toSet().toList()
      ..sort((a, b) => (a ?? -1).compareTo(b ?? -1));
    final ranges = _rangesFor(_itemsForSeason(_season));
    final safeRangeIndex = ranges.isEmpty
        ? 0
        : _rangeIndex.clamp(0, ranges.length - 1);
    final visible = ranges.isEmpty
        ? <PlayerEpisodePanelItem<T>>[]
        : ranges[safeRangeIndex].items;
    final tablet = MediaQuery.sizeOf(context).shortestSide >= 600;

    return Padding(
      padding: PlayerSidePanelTokens.contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${_season == null
                ? (zh ? '剧集' : 'Episodes')
                : _season == 0
                ? (zh ? '特别篇' : 'Specials')
                : (zh ? '第 $_season 季' : 'Season $_season')} · '
            '${_itemsForSeason(_season).length} ${zh ? '个条目' : 'items'}',
            style: const TextStyle(color: PlayerSidePanelTokens.textMuted),
          ),
          const SizedBox(height: 12),
          if (seasons.length > 1) ...[
            _Tabs(
              labels: [
                for (final season in seasons)
                  season == null
                      ? (zh ? '未知季' : 'Unknown season')
                      : season == 0
                      ? (zh ? '特别篇' : 'Specials')
                      : (zh ? '第 $season 季' : 'Season $season'),
              ],
              selected: seasons.indexOf(_season),
              onSelected: (index) {
                setState(() {
                  _season = seasons[index];
                  _rangeIndex = 0;
                  _resetGrid();
                });
              },
            ),
            const SizedBox(height: 10),
          ],
          if (ranges.length > 1) ...[
            _Tabs(
              labels: [
                for (final range in ranges)
                  range.label == 'unknown'
                      ? (zh ? '未知集号' : 'Unknown')
                      : range.label,
              ],
              selected: safeRangeIndex,
              onSelected: (index) => setState(() {
                _rangeIndex = index;
                _resetGrid();
              }),
            ),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      zh ? '暂无可选剧集' : 'No episodes available',
                      style: const TextStyle(
                        color: PlayerSidePanelTokens.textMuted,
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = tablet ? 2 : 1;
                      final currentIndex = visible.indexWhere(
                        (item) => item.id == widget.currentId,
                      );
                      final scope =
                          '${_season}_$safeRangeIndex'
                          '_${constraints.maxHeight}_$columns';
                      if (_gridController == null || _gridScope != scope) {
                        final old = _gridController;
                        final row = currentIndex < 0
                            ? 0
                            : currentIndex ~/ columns;
                        final centered =
                            row * 78.0 - (constraints.maxHeight - 68) / 2;
                        _gridController = ScrollController(
                          initialScrollOffset: centered
                              .clamp(0, double.infinity)
                              .toDouble(),
                        );
                        _gridScope = scope;
                        if (old != null) {
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => old.dispose(),
                          );
                        }
                      }
                      return GridView.builder(
                        key: ValueKey(
                          'episode-grid:${_season}_$safeRangeIndex',
                        ),
                        controller: _gridController,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          mainAxisExtent: 68,
                        ),
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final item = visible[index];
                          final current = item.id == widget.currentId;
                          return _EpisodeTile<T>(
                            key: ValueKey(item.id),
                            item: item,
                            current: current,
                            unavailableLabel: zh ? '不可用' : 'Unavailable',
                            onTap: item.available
                                ? () => widget.onSelected(item)
                                : null,
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _EpisodeRange<T> {
  const _EpisodeRange({required this.label, required this.items});
  final String label;
  final List<PlayerEpisodePanelItem<T>> items;
}

class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.labels,
    required this.selected,
    required this.onSelected,
  });
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (var index = 0; index < labels.length; index++)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: () => onSelected(index),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 44),
                foregroundColor: index == selected
                    ? PlayerSidePanelTokens.accent
                    : PlayerSidePanelTokens.textMuted,
                backgroundColor: index == selected
                    ? PlayerSidePanelTokens.selectedSurface
                    : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: index == selected
                        ? PlayerSidePanelTokens.accent.withValues(alpha: .45)
                        : PlayerSidePanelTokens.border,
                  ),
                ),
              ),
              child: Text(labels[index]),
            ),
          ),
      ],
    ),
  );
}

class _EpisodeTile<T> extends StatelessWidget {
  const _EpisodeTile({
    super.key,
    required this.item,
    required this.current,
    required this.unavailableLabel,
    required this.onTap,
  });
  final PlayerEpisodePanelItem<T> item;
  final bool current;
  final String unavailableLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: current
        ? PlayerSidePanelTokens.selectedSurface
        : PlayerSidePanelTokens.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: current
            ? PlayerSidePanelTokens.accent
            : PlayerSidePanelTokens.border,
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            if (item.number != null) ...[
              SizedBox(
                width: 34,
                child: Text(
                  '${item.number}',
                  style: TextStyle(
                    color: current
                        ? PlayerSidePanelTokens.accent
                        : PlayerSidePanelTokens.textMuted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: item.available
                          ? PlayerSidePanelTokens.text
                          : PlayerSidePanelTokens.textMuted,
                      fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  if (item.subtitle != null || !item.available)
                    Text(
                      item.available ? item.subtitle! : unavailableLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: current
                            ? PlayerSidePanelTokens.accent
                            : PlayerSidePanelTokens.textMuted,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

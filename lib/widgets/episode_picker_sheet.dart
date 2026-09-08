import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../library/episode_target.dart';
import '../library/models/library_models.dart';

class EpisodePickerSheet extends StatefulWidget {
  const EpisodePickerSheet({
    super.key,
    required this.episodes,
    required this.season,
    required this.currentEpisodeId,
    required this.isAvailable,
    required this.positionFor,
    this.total,
  });

  final List<LibraryEpisode> episodes;
  final int? season;
  final String? currentEpisodeId;
  final bool Function(LibraryEpisode) isAvailable;
  final Duration? Function(LibraryEpisode) positionFor;
  final int? total;

  @override
  State<EpisodePickerSheet> createState() => _EpisodePickerSheetState();
}

class _EpisodePickerSheetState extends State<EpisodePickerSheet> {
  final _groupsController = ScrollController();
  late final _groups = groupEpisodes(widget.episodes, total: widget.total);
  late int _selected = _initialGroup();
  bool _positionPending = true;
  bool _groupPositionPending = true;

  int _initialGroup() {
    final found = _groups.indexWhere(
      (group) => group.episodes.any(
        (episode) => episode.id == widget.currentEpisodeId,
      ),
    );
    return found < 0 ? 0 : found;
  }

  @override
  void dispose() {
    _groupsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final windowWidth = MediaQuery.sizeOf(context).width;
    final episodes = _groups.isEmpty
        ? <LibraryEpisode>[]
        : _groups[_selected].episodes;
    return DraggableScrollableSheet(
      initialChildSize: .72,
      minChildSize: .45,
      maxChildSize: .96,
      expand: false,
      builder: (context, controller) => Material(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.onSurface.withValues(alpha: .18),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: AppText(
                        widget.season == null
                            ? '选集'
                            : widget.season == 0
                            ? '选集 · 特别篇'
                            : '选集 · 第 ${widget.season} 季',
                        maxLines: 2,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AppText(
                    widget.total == null
                        ? '库中 ${widget.episodes.length} 集'
                        : '共 ${widget.total} 集 · 库中 ${widget.episodes.length} 集',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              ),
              if (_groups.isNotEmpty)
                SizedBox(
                  height: 36 * scale + 24,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final extent = 106.0 * scale;
                      if (_groupPositionPending) {
                        _groupPositionPending = false;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!_groupsController.hasClients) return;
                          _groupsController.jumpTo(
                            (_selected * extent -
                                    (constraints.maxWidth - extent) / 2)
                                .clamp(
                                  0.0,
                                  _groupsController.position.maxScrollExtent,
                                ),
                          );
                        });
                      }
                      return ListView.builder(
                        controller: _groupsController,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        itemExtent: extent,
                        itemCount: _groups.length,
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: ChoiceChip(
                            label: AppText(_groups[index].label),
                            showCheckmark: false,
                            selected: index == _selected,
                            onSelected: (_) {
                              setState(() {
                                _selected = index;
                                _positionPending = false;
                              });
                              if (controller.hasClients) controller.jumpTo(0);
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
              Expanded(
                child: episodes.isEmpty
                    ? const Center(child: AppText('这一季暂时没有可播放的剧集'))
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final desired = windowWidth >= 900
                              ? 4
                              : windowWidth >= 600
                              ? 3
                              : 2;
                          final columns = (constraints.maxWidth / (145 * scale))
                              .floor()
                              .clamp(1, desired);
                          final extent = 88.0 * scale + 18;
                          if (_positionPending) {
                            _positionPending = false;
                            final current = episodes.indexWhere(
                              (episode) =>
                                  episode.id == widget.currentEpisodeId,
                            );
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!controller.hasClients || current < 0) return;
                              controller.jumpTo(
                                ((current ~/ columns) * (extent + 10)).clamp(
                                  0.0,
                                  controller.position.maxScrollExtent,
                                ),
                              );
                            });
                          }
                          return GridView.builder(
                            controller: controller,
                            padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  mainAxisExtent: extent,
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                ),
                            itemCount: episodes.length,
                            itemBuilder: (context, index) {
                              final episode = episodes[index];
                              final selected =
                                  episode.id == widget.currentEpisodeId;
                              final available = widget.isAvailable(episode);
                              final position = widget.positionFor(episode);
                              return Material(
                                key: ValueKey('picker-${episode.id}'),
                                color: selected
                                    ? colors.secondaryContainer
                                    : colors.surfaceContainerLow,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(
                                    color: selected
                                        ? colors.onSurface
                                        : Colors.transparent,
                                  ),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: available
                                      ? () => Navigator.pop(context, episode)
                                      : null,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        AppText(
                                          episode.episodeNumber <= 0
                                              ? '未知集号'
                                              : '第 ${episode.episodeNumber} 集',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            color: available
                                                ? colors.onSurface
                                                : colors.onSurfaceVariant,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        AppText(
                                          episode.displayName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const Spacer(),
                                        AppText(
                                          !available
                                              ? '不可用'
                                              : position != null
                                              ? selected
                                                    ? '继续观看 ${_clock(position)}'
                                                    : '看到 ${_clock(position)}'
                                              : selected
                                              ? '当前推荐'
                                              : '播放',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _clock(Duration value) {
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return value.inHours > 0
      ? '${value.inHours}:$minutes:$seconds'
      : '$minutes:$seconds';
}

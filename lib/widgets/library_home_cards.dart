import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../library/models/library_models.dart';
import '../services/recent_library_items.dart';

class SavedSourceTile extends StatelessWidget {
  const SavedSourceTile({
    super.key,
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.onLongPress,
  });

  final String name;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$name，$subtitle',
      child: ListTile(
        minTileHeight: 80,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        leading: SizedBox.square(
          dimension: 48,
          child: Icon(
            icon,
            size: 32,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        title: AppText(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: AppText(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}

String playbackTime(Duration value) {
  final seconds = value.inSeconds.clamp(0, 359999);
  final minutes = (seconds ~/ 60).remainder(60).toString().padLeft(2, '0');
  final tail = (seconds % 60).toString().padLeft(2, '0');
  return seconds >= 3600
      ? '${seconds ~/ 3600}:$minutes:$tail'
      : '$minutes:$tail';
}

class LibraryArtwork extends StatelessWidget {
  const LibraryArtwork({super.key, this.url, this.fallbackUrl});
  final String? url;
  final String? fallbackUrl;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    Widget fallback() => fallbackUrl == null || fallbackUrl == url
        ? placeholder
        : Image.network(
            fallbackUrl!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => placeholder,
          );
    return url == null || url!.isEmpty
        ? fallback()
        : Image.network(
            url!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback(),
          );
  }
}

class LibraryPosterCard extends StatelessWidget {
  const LibraryPosterCard({
    super.key,
    required this.title,
    required this.onTap,
  });
  final MediaTitle title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LibraryArtwork(
                    url: title.poster,
                    fallbackUrl: title.backdrop,
                  ),
                  if (title.rating > 0)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 3,
                        ),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(5),
                          ),
                        ),
                        child: Text(
                          title.rating.toStringAsFixed(1),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          Text(
            title.releaseDate ?? title.year?.toString() ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

class RecentLibraryCard extends StatelessWidget {
  const RecentLibraryCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.onRemove,
  });
  final RecentLibraryItem item;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final entry = item.entry;
    final metadata = item.metadata;
    final season = metadata?.seasonNumber;
    final episode = metadata?.episodeNumber;
    final chinese = AppLocalizations.of(context).isChinese;
    final label = [
      item.displayTitle,
      if (season != null) chinese ? '第 $season 季' : 'S$season',
      if (episode != null) chinese ? '第 $episode 集' : 'E$episode',
      if (metadata?.episodeTitle?.isNotEmpty == true) metadata!.episodeTitle!,
    ].join(' ');
    final duration = entry.video.duration;
    final progress = duration > Duration.zero
        ? (entry.position.inMilliseconds / duration.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    LibraryArtwork(
                      url: item.artwork,
                      fallbackUrl: item.title?.backdrop ?? item.title?.poster,
                    ),
                    const Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 6,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .7),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          '${playbackTime(entry.position)}${duration > Duration.zero ? '/${playbackTime(duration)}' : ''}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    if (progress != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 3,
                          color: Theme.of(context).colorScheme.onSurface,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: context.tr('More'),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_horiz, size: 20),
                  onSelected: (_) => onRemove(),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'remove', child: AppText('Remove')),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

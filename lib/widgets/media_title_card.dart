import '../widgets/cached_image.dart';
import 'package:flutter/material.dart';

import '../library/models/library_models.dart';
import '../l10n/app_localizations.dart';

class MediaTitleCard extends StatelessWidget {
  const MediaTitleCard({
    super.key,
    required this.title,
    required this.episodeCount,
    required this.versionCount,
    required this.onTap,
  });

  final MediaTitle title;
  final int episodeCount;
  final int versionCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final subtitle = title.kind == MediaTitleKind.movie
        ? [if (title.year != null) '${title.year}', 'Movie'].join(' · ')
        : [
            if (title.year != null) '${title.year}',
            '$episodeCount episodes',
            if (versionCount > episodeCount) '$versionCount versions',
          ].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: colors.surfaceContainerHighest,
                    child: Icon(
                      Icons.movie_outlined,
                      size: 48,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (title.poster != null)
                    CachedImage(
                      title.poster!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    title.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  AppText(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

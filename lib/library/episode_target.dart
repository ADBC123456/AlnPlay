import '../services/continue_watching.dart';
import 'models/library_models.dart';
import 'repository/library_repository.dart';

/// One stable recommendation shared by the hero, season, rail and picker.
class EpisodeTarget {
  const EpisodeTarget(
    this.episode,
    this.file, {
    this.progress,
    this.replay = false,
  });
  final LibraryEpisode episode;
  final MediaFile file;
  final ContinueWatchingEntry? progress;
  final bool replay;
}

int compareLibraryEpisodes(LibraryEpisode a, LibraryEpisode b) {
  final season = (a.seasonNumber ?? 1 << 20).compareTo(
    b.seasonNumber ?? 1 << 20,
  );
  return season == 0 ? a.episodeNumber.compareTo(b.episodeNumber) : season;
}

EpisodeTarget? resolveEpisodeTarget({
  required LibrarySnapshot snapshot,
  required String titleId,
  required List<ContinueWatchingEntry> progress,
  TitlePlaybackPreference? preference,
  Set<String> watchedKeys = const {},
}) {
  final episodes =
      snapshot.episodes.values
          .where((episode) => episode.titleId == titleId)
          .toList()
        ..sort(compareLibraryEpisodes);
  final files = snapshot.filesForTitle(titleId);
  LibraryEpisode? episodeFor(ContinueWatchingEntry entry) {
    final key = ContinueWatchingStore.keyFor(entry.video);
    final file = files.where((file) => file.legacyResumeKey == key).firstOrNull;
    if (file?.episodeId != null) {
      final exact = snapshot.episodes[file!.episodeId];
      if (exact != null) return exact;
    }
    if (file != null) {
      final reconciled = episodes
          .where(
            (episode) => snapshot
                .versionsForEpisode(episode.id)
                .any((version) => version.id == file.id),
          )
          .firstOrNull;
      if (reconciled != null) return reconciled;
    }
    final metadata = entry.video.metadataContext;
    if (metadata?.titleId != titleId || metadata?.episodeNumber == null) {
      return null;
    }
    // Never match the episode number alone across seasons.
    return episodes
        .where(
          (episode) =>
              episode.seasonNumber == metadata!.seasonNumber &&
              episode.episodeNumber == metadata.episodeNumber,
        )
        .firstOrNull;
  }

  final history = progress.where((entry) => episodeFor(entry) != null).toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final latest = history.firstOrNull;
  final preferStored =
      preference?.lastPlayedEpisodeId != null &&
      (latest == null ||
          (preference?.lastPlayedAt?.isAfter(latest.updatedAt) ?? false));
  final recent = preferStored
      ? snapshot.episodes[preference!.lastPlayedEpisodeId]
      : latest == null
      ? null
      : episodeFor(latest);
  final recentFile = preferStored
      ? snapshot.files[preference!.lastPlayedFileId]
      : latest == null
      ? null
      : files
            .where(
              (file) =>
                  file.legacyResumeKey ==
                  ContinueWatchingStore.keyFor(latest.video),
            )
            .firstOrNull;
  final duration = latest?.video.duration ?? Duration.zero;
  final completed =
      recent != null &&
      ((preferStored && watchedKeys.contains(recentFile?.legacyResumeKey)) ||
          (!preferStored &&
              duration > Duration.zero &&
              latest!.position >= duration - const Duration(seconds: 2)));

  EpisodeTarget? targetFor(LibraryEpisode episode, {bool replay = false}) {
    final versions = snapshot.versionsForEpisode(episode.id);
    if (versions.isEmpty) return null;
    final file =
        versions.where((file) => file.id == recentFile?.id).firstOrNull ??
        versions
            .where(
              (file) =>
                  file.sourceRef.sourceId == preference?.preferredSourceId,
            )
            .firstOrNull ??
        versions.first;
    final entry = replay
        ? null
        : history
              .where(
                (entry) =>
                    ContinueWatchingStore.keyFor(entry.video) ==
                    file.legacyResumeKey,
              )
              .firstOrNull;
    return EpisodeTarget(episode, file, progress: entry, replay: replay);
  }

  if (recent != null) {
    if (!completed) {
      final same = targetFor(recent);
      if (same != null) return same;
    }
    for (final episode in episodes.skip(episodes.indexOf(recent) + 1)) {
      // Special/unknown seasons do not become the next regular episode.
      if (recent.seasonNumber != null &&
          recent.seasonNumber! > 0 &&
          (episode.seasonNumber == null || episode.seasonNumber == 0)) {
        continue;
      }
      final next = targetFor(episode);
      if (next != null) return next;
    }
    final replay = targetFor(recent, replay: completed);
    if (replay != null) return replay;
  }
  final regular = episodes.where((episode) => (episode.seasonNumber ?? 0) > 0);
  for (final episode in [...regular, ...episodes]) {
    final target = targetFor(episode);
    if (target != null) return target;
  }
  return null;
}

class EpisodeGroup {
  const EpisodeGroup(this.start, this.end, this.episodes);
  final int? start;
  final int? end;
  final List<LibraryEpisode> episodes;
  String get label => start == null ? '未知集号' : '$start–$end';
}

/// Bucket by real episode numbers, so missing files never shift boundaries.
List<EpisodeGroup> groupEpisodes(List<LibraryEpisode> episodes, {int? total}) {
  final buckets = <int, List<LibraryEpisode>>{};
  var maximum = 0;
  for (final episode in episodes) {
    final number = episode.episodeNumber;
    if (number > maximum) maximum = number;
    buckets
        .putIfAbsent(number <= 0 ? -1 : (number - 1) ~/ 50, () => [])
        .add(episode);
  }
  final bound = total != null && total > maximum ? total : maximum;
  final keys = buckets.keys.where((key) => key >= 0).toList()..sort();
  if (buckets.containsKey(-1)) keys.add(-1);
  return [
    for (final key in keys)
      EpisodeGroup(
        key < 0 ? null : key * 50 + 1,
        key < 0 ? null : ((key + 1) * 50).clamp(0, bound),
        buckets[key]!..sort(compareLibraryEpisodes),
      ),
  ];
}

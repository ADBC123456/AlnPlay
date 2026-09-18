import 'dart:async';

import '../../services/tmdb_client.dart';
import '../../services/image_cache_service.dart';
import '../models/library_models.dart';
import '../repository/library_repository.dart';

class TmdbLibraryMetadataResolver implements MetadataResolver {
  TmdbLibraryMetadataResolver({required this.repository, TmdApi? api})
    : _api = api ?? TmdApi();

  static const double minimumAutomaticScore = 0.8;
  static const double minimumCandidateLead = 0.1;
  static const Duration minimumRequestSpacing = Duration(milliseconds: 300);
  static const int maximumConcurrentRequests = 2;

  final LibraryRepository repository;
  final TmdApi _api;
  final Map<String, Future<List<TmdMovie>>> _sharedSearches = {};
  final Map<String, Future<TmdDetails>> _sharedDetails = {};
  final Map<String, Future<List<TmdEpisode>>> _sharedSeasons = {};
  final List<Completer<void>> _waiters = [];
  int _activeRequests = 0;
  DateTime? _lastRequestStartedAt;

  @override
  Future<MatchResult> resolve(MediaFile file, DiscoveryContext context) async {
    final snapshot = await repository.snapshot();
    final currentFile = snapshot.files[file.id];
    if (currentFile != null &&
        currentFile.matchRevision != file.matchRevision) {
      file = file.copyWith(matchRevision: currentFile.matchRevision);
    }
    final override = snapshot.overrides[file.id];
    if (override != null) {
      final episodeId = override.episodeNumber == null
          ? null
          : '${override.pinnedTitleId}:s${override.seasonNumber ?? 'unknown'}'
                ':e${override.episodeNumber}';
      return MatchResult(
        file: file.copyWith(
          titleId: override.pinnedTitleId,
          episodeId: episodeId,
          matchOrigin: MatchOrigin.manual,
          identificationState: MetadataState.matched,
        ),
        title: snapshot.titles[override.pinnedTitleId],
        episode: episodeId == null ? null : snapshot.episodes[episodeId],
      );
    }
    if (file.titleId != null && file.matchOrigin == MatchOrigin.server) {
      return MatchResult(
        file: file.copyWith(identificationState: MetadataState.matched),
      );
    }

    final rootId = context.rootId;
    final folderMeta = rootId == null
        ? null
        : TmdService.instance.metaFor('folder:$rootId');
    if (folderMeta != null && _inheritsRootBinding(context.directoryNames)) {
      return _resolveFromFolderMatch(file, context, folderMeta);
    }
    if (folderMeta?.movie.kind == TmdKind.tv &&
        context.directoryNames.length > 1) {
      try {
        final details =
            folderMeta!.details ??
            await TmdService.instance.detailsFor('folder:$rootId') ??
            await _detailsShared(folderMeta.movie);
        final arc = context.directoryNames
            .skip(1)
            .where(
              (name) =>
                  !ParsedFileName.isContainerDirectory(name) &&
                  !ParsedFileName.isSeasonDirectory(name),
            )
            .toList();
        final season = arc.length == 1
            ? details.seasonForFolder(arc.single)
            : null;
        if (season != null) {
          return _resolveFromFolderMatch(
            file,
            context,
            folderMeta.withDetails(details),
            inferredSeason: season,
          );
        }
      } on Exception {
        // Unknown/offline season names must not force an arc into the last season.
      }
    }

    final key = await _api.effectiveApiKey();
    if (key.isEmpty) {
      return MatchResult(
        file: file.copyWith(identificationState: MetadataState.noApiKey),
      );
    }
    final parsed = ParsedFileName.parseWithAncestors(
      file.originalFileName,
      context.directoryNames,
    );
    if (parsed.title.trim().isEmpty) {
      return MatchResult(
        file: file.copyWith(identificationState: MetadataState.needsReview),
      );
    }
    if (parsed.isEpisode &&
        (!(parsed.seriesName?.isNotEmpty ?? false) || !parsed.seasonKnown)) {
      return MatchResult(
        file: file.copyWith(identificationState: MetadataState.needsReview),
      );
    }

    try {
      final hasSeries =
          parsed.isEpisode || (parsed.seriesName?.isNotEmpty ?? false);
      final kind = hasSeries ? TmdKind.tv : TmdKind.movie;
      final query = hasSeries
          ? (parsed.seriesName ?? parsed.title)
          : parsed.title;
      final candidates = await _searchShared(query, parsed.year, kind);
      if (candidates.isEmpty) {
        return MatchResult(
          file: file.copyWith(identificationState: MetadataState.noMatch),
        );
      }
      final scored = [
        for (final candidate in candidates)
          (movie: candidate, score: _api.scoreCandidate(candidate, parsed)),
      ]..sort((a, b) => b.score.compareTo(a.score));
      final best = scored.first;
      final lead = scored.length < 2 ? 1.0 : best.score - scored[1].score;
      if (best.score < minimumAutomaticScore ||
          lead < minimumCandidateLead ||
          (parsed.year != null &&
              best.movie.year != null &&
              parsed.year != best.movie.year)) {
        return MatchResult(
          file: file.copyWith(identificationState: MetadataState.needsReview),
        );
      }

      final titleId = 'tmdb:${kind.name}:${best.movie.id}';
      TmdDetails? details;
      try {
        details = await _detailsShared(best.movie);
      } on Exception {
        // Search metadata is sufficient to index and play the file. A later
        // refresh can enrich it when the details endpoint is reachable.
      }
      final title = MediaTitle(
        id: titleId,
        kind: kind == TmdKind.tv ? MediaTitleKind.tv : MediaTitleKind.movie,
        tmdbId: best.movie.id,
        displayTitle: best.movie.title,
        originalTitle: details?.originalTitle ?? best.movie.originalTitle,
        year: details?.year ?? best.movie.year,
        releaseDate: details?.releaseDate ?? best.movie.releaseDate,
        genres: details?.genres ?? const [],
        poster: _imageUrl(details?.posterPath) ?? best.movie.posterUrl(),
        backdrop:
            _imageUrl(details?.backdropPath, width: 1280) ??
            best.movie.backdropUrl(),
        overview: details?.overview.isNotEmpty == true
            ? details!.overview
            : best.movie.overview,
        rating: details != null && details.voteAverage > 0
            ? details.voteAverage
            : best.movie.voteAverage,
        totalEpisodeCount: details?.numberOfEpisodes == 0
            ? null
            : details?.numberOfEpisodes,
        metadataLanguage: await _api.effectiveLanguageTag(),
      );
      LibraryEpisode? episode;
      String? episodeId;
      if (parsed.isEpisode && parsed.episode > 0) {
        episodeId = '$titleId:s${parsed.season}:e${parsed.episode}';
        TmdEpisode? officialEpisode;
        try {
          final season = await _seasonShared(best.movie, parsed.season);
          officialEpisode = season
              .where((item) => item.episodeNumber == parsed.episode)
              .firstOrNull;
        } on Exception {
          // Keep the stable placeholder episode when season metadata fails.
        }
        episode = LibraryEpisode(
          id: episodeId,
          titleId: titleId,
          seasonNumber: parsed.season,
          episodeNumber: parsed.episode,
          displayName:
              officialEpisode?.nameLabel ?? 'Episode ${parsed.episode}',
          still: officialEpisode?.stillUrl(width: 500),
          runtime: officialEpisode?.runtimeMinutes == null
              ? null
              : Duration(minutes: officialEpisode!.runtimeMinutes!),
        );
      }
      _prefetchArtwork(title, episode, details);
      return MatchResult(
        file: file.copyWith(
          titleId: titleId,
          episodeId: episodeId,
          matchOrigin: MatchOrigin.automatic,
          identificationState: MetadataState.matched,
        ),
        title: title,
        episode: episode,
      );
    } on TmdException {
      return MatchResult(
        file: file.copyWith(identificationState: MetadataState.failed),
      );
    } on Exception {
      return MatchResult(
        file: file.copyWith(identificationState: MetadataState.offline),
      );
    }
  }

  Future<MatchResult> _resolveFromFolderMatch(
    MediaFile file,
    DiscoveryContext context,
    TmdMeta meta, {
    int? inferredSeason,
  }) async {
    final movie = meta.movie;
    var parsed = ParsedFileName.parseWithAncestors(
      file.originalFileName,
      context.directoryNames,
    );
    if (!parsed.seasonKnown && parsed.isEpisode && inferredSeason != null) {
      parsed = ParsedFileName(
        title: movie.title,
        seriesName: movie.title,
        year: parsed.year,
        isEpisode: true,
        episode: parsed.episode,
        season: inferredSeason,
        seasonKnown: true,
        liveAction: parsed.liveAction,
      );
    }
    TmdDetails? details = meta.details;
    if (details == null) {
      try {
        details = await _detailsShared(movie);
      } on Exception {
        // The confirmed folder match is enough to build the library. Enrich
        // it on a later refresh when TMDB becomes reachable again.
      }
    }
    final titleId = 'tmdb:${movie.kind.name}:${movie.id}';
    final title = MediaTitle(
      id: titleId,
      kind: movie.kind == TmdKind.tv ? MediaTitleKind.tv : MediaTitleKind.movie,
      tmdbId: movie.id,
      displayTitle: details?.title.isNotEmpty == true
          ? details!.title
          : movie.title,
      originalTitle: details?.originalTitle ?? movie.originalTitle,
      year: details?.year ?? movie.year,
      releaseDate: details?.releaseDate ?? movie.releaseDate,
      genres: details?.genres ?? const [],
      poster: _imageUrl(details?.posterPath) ?? movie.posterUrl(),
      backdrop:
          _imageUrl(details?.backdropPath, width: 1280) ?? movie.backdropUrl(),
      overview: details?.overview.isNotEmpty == true
          ? details!.overview
          : movie.overview,
      rating: details != null && details.voteAverage > 0
          ? details.voteAverage
          : movie.voteAverage,
      totalEpisodeCount: details?.numberOfEpisodes == 0
          ? null
          : details?.numberOfEpisodes,
      metadataLanguage: await _api.effectiveLanguageTag(),
    );

    LibraryEpisode? episode;
    String? episodeId;
    if (movie.kind == TmdKind.tv &&
        parsed.isEpisode &&
        parsed.seasonKnown &&
        parsed.episode > 0) {
      episodeId = '$titleId:s${parsed.season}:e${parsed.episode}';
      TmdEpisode? official = meta.seasons[parsed.season]?.episode(
        parsed.episode,
      );
      if (official == null) {
        try {
          official = (await _seasonShared(
            movie,
            parsed.season,
          )).where((item) => item.episodeNumber == parsed.episode).firstOrNull;
        } on Exception {
          // Keep the parsed episode identity and filename-derived title.
        }
      }
      episode = LibraryEpisode(
        id: episodeId,
        titleId: titleId,
        seasonNumber: parsed.season,
        episodeNumber: parsed.episode,
        displayName: official?.nameLabel ?? '第 ${parsed.episode} 集',
        still: official?.stillUrl(width: 500),
        runtime: official?.runtimeMinutes == null
            ? null
            : Duration(minutes: official!.runtimeMinutes!),
      );
    }
    _prefetchArtwork(title, episode, details);
    return MatchResult(
      file: file.copyWith(
        titleId: titleId,
        episodeId: episodeId,
        matchOrigin: MatchOrigin.automatic,
        identificationState: episodeId == null && movie.kind == TmdKind.tv
            ? MetadataState.needsReview
            : MetadataState.matched,
      ),
      title: title,
      episode: episode,
    );
  }

  Future<List<TmdMovie>> _searchShared(
    String query,
    int? year,
    TmdKind kind,
  ) async {
    final language = await _api.effectiveLanguageTag();
    final normalized = query.trim().toLowerCase();
    final key = '$normalized|${kind.name}|${year ?? ''}|$language';
    final existing = _sharedSearches[key];
    if (existing != null) return existing;
    final future = _scheduledSearch(query, year, kind);
    _sharedSearches[key] = future;
    try {
      return await future;
    } finally {
      _sharedSearches.remove(key);
    }
  }

  Future<List<TmdMovie>> _scheduledSearch(
    String query,
    int? year,
    TmdKind kind,
  ) => _scheduled(() => _api.search(query, year: year, kind: kind));

  Future<TmdDetails> _detailsShared(TmdMovie movie) async {
    final language = await _api.effectiveLanguageTag();
    final key = '${movie.kind.name}:${movie.id}:$language';
    final existing = _sharedDetails[key];
    if (existing != null) return existing;
    final future = _scheduled(() => _api.details(movie));
    _sharedDetails[key] = future;
    try {
      return await future;
    } finally {
      _sharedDetails.remove(key);
    }
  }

  Future<List<TmdEpisode>> _seasonShared(TmdMovie movie, int season) async {
    final language = await _api.effectiveLanguageTag();
    final key = '${movie.id}:$season:$language';
    final existing = _sharedSeasons[key];
    if (existing != null) return existing;
    final future = _scheduled(() => _api.seasonEpisodes(movie, season));
    _sharedSeasons[key] = future;
    try {
      return await future;
    } finally {
      _sharedSeasons.remove(key);
    }
  }

  Future<T> _scheduled<T>(Future<T> Function() request) async {
    await _acquireRequestSlot();
    try {
      final last = _lastRequestStartedAt;
      if (last != null) {
        final remaining =
            minimumRequestSpacing - DateTime.now().difference(last);
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      }
      _lastRequestStartedAt = DateTime.now();
      return await request();
    } finally {
      _releaseRequestSlot();
    }
  }

  Future<void> _acquireRequestSlot() async {
    if (_activeRequests < maximumConcurrentRequests) {
      _activeRequests++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
    _activeRequests++;
  }

  void _releaseRequestSlot() {
    _activeRequests--;
    if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
  }

  static String? _imageUrl(String? path, {int width = 342}) =>
      path == null ? null : 'https://image.tmdb.org/t/p/w$width$path';

  static void _prefetchArtwork(
    MediaTitle title,
    LibraryEpisode? episode,
    TmdDetails? details,
  ) {
    ImageCacheService.instance.prefetch([
      title.poster,
      title.backdrop,
      episode?.still,
      ...?details?.cast.map((person) => person.profileUrl()),
    ]);
  }

  static bool _inheritsRootBinding(List<String> ancestors) =>
      ancestors.isNotEmpty &&
      !ParsedFileName.isContainerDirectory(ancestors.first) &&
      ancestors
          .skip(1)
          .every(
            (name) =>
                ParsedFileName.isSeasonDirectory(name) ||
                ParsedFileName.isContainerDirectory(name),
          );
}

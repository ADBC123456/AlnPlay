import '../../models/video_item.dart';

enum MediaTitleKind { movie, tv }

enum MetadataState {
  unresolved,
  matched,
  needsReview,
  noApiKey,
  offline,
  noMatch,
  failed,
}

enum MatchOrigin { automatic, server, manual }

enum MediaAvailability { available, unknown, missing }

class MediaTitle {
  const MediaTitle({
    required this.id,
    required this.kind,
    required this.tmdbId,
    required this.displayTitle,
    this.originalTitle,
    this.year,
    this.releaseDate,
    this.genres = const [],
    this.poster,
    this.backdrop,
    this.overview = '',
    this.rating = 0,
    this.totalEpisodeCount,
    this.metadataState = MetadataState.matched,
    this.metadataLanguage,
    this.revision = 0,
  });

  final String id;
  final MediaTitleKind kind;
  final int tmdbId;
  final String displayTitle;
  final String? originalTitle;
  final int? year;
  final String? releaseDate;
  final List<String> genres;

  /// True only when a metadata provider explicitly classifies the title as
  /// animation. Deliberately does not infer from file, folder, or title text.
  bool get isAnimation => genres.any((genre) {
    final normalized = genre.trim().toLowerCase();
    return normalized == 'animation' ||
        normalized == 'anime' ||
        normalized == '动画' ||
        normalized == '動畫' ||
        normalized == 'アニメーション';
  });
  final String? poster;
  final String? backdrop;
  final String overview;
  final double rating;

  /// Total episodes reported by metadata. Null means the provider did not
  /// supply a trustworthy total (movies and partially identified titles).
  final int? totalEpisodeCount;
  final MetadataState metadataState;
  final String? metadataLanguage;
  final int revision;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'tmdbId': tmdbId,
    'displayTitle': displayTitle,
    if (originalTitle != null) 'originalTitle': originalTitle,
    if (year != null) 'year': year,
    if (releaseDate != null) 'releaseDate': releaseDate,
    'genres': genres,
    if (poster != null) 'poster': poster,
    if (backdrop != null) 'backdrop': backdrop,
    'overview': overview,
    'rating': rating,
    if (totalEpisodeCount != null) 'totalEpisodeCount': totalEpisodeCount,
    'metadataState': metadataState.name,
    if (metadataLanguage != null) 'metadataLanguage': metadataLanguage,
    'revision': revision,
  };

  factory MediaTitle.fromJson(Map<String, dynamic> json) => MediaTitle(
    id: json['id'] as String? ?? '',
    kind: _enumByName(
      MediaTitleKind.values,
      json['kind'] as String?,
      MediaTitleKind.movie,
    ),
    tmdbId: (json['tmdbId'] as num?)?.toInt() ?? 0,
    displayTitle: json['displayTitle'] as String? ?? '',
    originalTitle: json['originalTitle'] as String?,
    year: (json['year'] as num?)?.toInt(),
    releaseDate: json['releaseDate'] as String?,
    genres: (json['genres'] as List? ?? const []).whereType<String>().toList(),
    poster: json['poster'] as String?,
    backdrop: json['backdrop'] as String?,
    overview: json['overview'] as String? ?? '',
    rating: (json['rating'] as num?)?.toDouble() ?? 0,
    totalEpisodeCount: (json['totalEpisodeCount'] as num?)?.toInt(),
    metadataState: _enumByName(
      MetadataState.values,
      json['metadataState'] as String?,
      MetadataState.matched,
    ),
    metadataLanguage: json['metadataLanguage'] as String?,
    revision: (json['revision'] as num?)?.toInt() ?? 0,
  );
}

class LibraryEpisode {
  const LibraryEpisode({
    required this.id,
    required this.titleId,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.displayName,
    this.still,
    this.runtime,
  });

  final String id;
  final String titleId;
  final int? seasonNumber;
  final int episodeNumber;
  final String displayName;
  final String? still;
  final Duration? runtime;

  Map<String, dynamic> toJson() => {
    'id': id,
    'titleId': titleId,
    if (seasonNumber != null) 'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'displayName': displayName,
    if (still != null) 'still': still,
    if (runtime != null) 'runtimeMs': runtime!.inMilliseconds,
  };

  factory LibraryEpisode.fromJson(Map<String, dynamic> json) => LibraryEpisode(
    id: json['id'] as String? ?? '',
    titleId: json['titleId'] as String? ?? '',
    seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
    episodeNumber: (json['episodeNumber'] as num?)?.toInt() ?? 0,
    displayName: json['displayName'] as String? ?? '',
    still: json['still'] as String?,
    runtime: json['runtimeMs'] == null
        ? null
        : Duration(milliseconds: (json['runtimeMs'] as num).toInt()),
  );
}

class MediaSourceRef {
  const MediaSourceRef({
    required this.sourceId,
    required this.sourceType,
    required this.path,
    this.serverId,
    this.itemId,
    this.share,
  });

  final String sourceId;
  final String sourceType;
  final String path;
  final String? serverId;
  final String? itemId;
  final String? share;

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'sourceType': sourceType,
    'path': path,
    if (serverId != null) 'serverId': serverId,
    if (itemId != null) 'itemId': itemId,
    if (share != null) 'share': share,
  };

  factory MediaSourceRef.fromJson(Map<String, dynamic> json) => MediaSourceRef(
    sourceId: json['sourceId'] as String? ?? '',
    sourceType: json['sourceType'] as String? ?? '',
    path: json['path'] as String? ?? '',
    serverId: json['serverId'] as String?,
    itemId: json['itemId'] as String?,
    share: json['share'] as String?,
  );
}

class MediaFile {
  const MediaFile({
    required this.id,
    required this.rootIds,
    required this.sourceRef,
    required this.originalFileName,
    this.sizeBytes,
    this.modifiedAt,
    this.discoveredAt,
    this.titleId,
    this.episodeId,
    this.matchOrigin,
    this.identificationState = MetadataState.unresolved,
    this.availability = MediaAvailability.unknown,
    required this.legacyResumeKey,
    this.matchRevision = 0,
    this.isStrm = false,
  });

  final String id;
  final Set<String> rootIds;
  final MediaSourceRef sourceRef;
  final String originalFileName;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final DateTime? discoveredAt;
  final String? titleId;
  final String? episodeId;
  final MatchOrigin? matchOrigin;
  final MetadataState identificationState;
  final MediaAvailability availability;
  final String legacyResumeKey;
  final int matchRevision;
  final bool isStrm;

  static const Object _unset = Object();

  MediaFile copyWith({
    Set<String>? rootIds,
    Object? titleId = _unset,
    Object? episodeId = _unset,
    MatchOrigin? matchOrigin,
    MetadataState? identificationState,
    MediaAvailability? availability,
    int? matchRevision,
  }) => MediaFile(
    id: id,
    rootIds: rootIds ?? this.rootIds,
    sourceRef: sourceRef,
    originalFileName: originalFileName,
    sizeBytes: sizeBytes,
    modifiedAt: modifiedAt,
    discoveredAt: discoveredAt,
    titleId: identical(titleId, _unset) ? this.titleId : titleId as String?,
    episodeId: identical(episodeId, _unset)
        ? this.episodeId
        : episodeId as String?,
    matchOrigin: matchOrigin ?? this.matchOrigin,
    identificationState: identificationState ?? this.identificationState,
    availability: availability ?? this.availability,
    legacyResumeKey: legacyResumeKey,
    matchRevision: matchRevision ?? this.matchRevision,
    isStrm: isStrm,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'rootIds': rootIds.toList()..sort(),
    'sourceRef': sourceRef.toJson(),
    'originalFileName': originalFileName,
    if (sizeBytes != null) 'sizeBytes': sizeBytes,
    if (modifiedAt != null) 'modifiedAtMs': modifiedAt!.millisecondsSinceEpoch,
    if (discoveredAt != null)
      'discoveredAtMs': discoveredAt!.millisecondsSinceEpoch,
    if (titleId != null) 'titleId': titleId,
    if (episodeId != null) 'episodeId': episodeId,
    if (matchOrigin != null) 'matchOrigin': matchOrigin!.name,
    'identificationState': identificationState.name,
    'availability': availability.name,
    'legacyResumeKey': legacyResumeKey,
    'matchRevision': matchRevision,
    if (isStrm) 'isStrm': true,
  };

  factory MediaFile.fromJson(Map<String, dynamic> json) => MediaFile(
    id: json['id'] as String? ?? '',
    rootIds: (json['rootIds'] as List? ?? const []).whereType<String>().toSet(),
    sourceRef: MediaSourceRef.fromJson(
      (json['sourceRef'] as Map? ?? const {}).cast<String, dynamic>(),
    ),
    originalFileName: json['originalFileName'] as String? ?? '',
    sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
    modifiedAt: _dateFromMs(json['modifiedAtMs']),
    discoveredAt: _dateFromMs(json['discoveredAtMs']),
    titleId: json['titleId'] as String?,
    episodeId: json['episodeId'] as String?,
    matchOrigin: json['matchOrigin'] == null
        ? null
        : _enumByName(
            MatchOrigin.values,
            json['matchOrigin'] as String?,
            MatchOrigin.automatic,
          ),
    identificationState: _enumByName(
      MetadataState.values,
      json['identificationState'] as String?,
      MetadataState.unresolved,
    ),
    availability: _enumByName(
      MediaAvailability.values,
      json['availability'] as String?,
      MediaAvailability.unknown,
    ),
    legacyResumeKey: json['legacyResumeKey'] as String? ?? '',
    matchRevision: (json['matchRevision'] as num?)?.toInt() ?? 0,
    isStrm: json['isStrm'] == true,
  );
}

class LibraryOverride {
  const LibraryOverride({
    required this.fileId,
    required this.pinnedTitleId,
    this.seasonNumber,
    this.episodeNumber,
    this.revision = 0,
  });

  final String fileId;
  final String pinnedTitleId;
  final int? seasonNumber;
  final int? episodeNumber;
  final int revision;

  Map<String, dynamic> toJson() => {
    'fileId': fileId,
    'pinnedTitleId': pinnedTitleId,
    if (seasonNumber != null) 'seasonNumber': seasonNumber,
    if (episodeNumber != null) 'episodeNumber': episodeNumber,
    'revision': revision,
  };

  factory LibraryOverride.fromJson(Map<String, dynamic> json) =>
      LibraryOverride(
        fileId: json['fileId'] as String? ?? '',
        pinnedTitleId: json['pinnedTitleId'] as String? ?? '',
        seasonNumber: (json['seasonNumber'] as num?)?.toInt(),
        episodeNumber: (json['episodeNumber'] as num?)?.toInt(),
        revision: (json['revision'] as num?)?.toInt() ?? 0,
      );
}

class TitlePlaybackPreference {
  const TitlePlaybackPreference({
    required this.titleId,
    this.preferredSourceId,
    this.lastPlayedFileId,
    this.lastPlayedEpisodeId,
    this.lastPlayedAt,
  });

  final String titleId;
  final String? preferredSourceId;
  final String? lastPlayedFileId;
  final String? lastPlayedEpisodeId;
  final DateTime? lastPlayedAt;
}

class LibraryRoot {
  const LibraryRoot({
    required this.id,
    required this.sourceId,
    required this.directory,
    required this.displayName,
    this.maxScanDepth = defaultMaxScanDepth,
  }) : assert(
         maxScanDepth >= minimumMaxScanDepth &&
             maxScanDepth <= maximumMaxScanDepth,
       );

  static const int defaultMaxScanDepth = 6;
  static const int minimumMaxScanDepth = 1;
  static const int maximumMaxScanDepth = 20;

  final String id;
  final String sourceId;
  final SourceDirectory directory;
  final String displayName;
  final int maxScanDepth;
}

class SourceDirectory {
  const SourceDirectory({
    required this.sourceId,
    required this.sourceType,
    required this.identity,
    required this.path,
    this.contextName,
    this.serverId,
    this.share,
  });

  final String sourceId;
  final String sourceType;
  final String identity;
  final String path;
  final String? contextName;
  final String? serverId;
  final String? share;
}

class SourceEntry {
  const SourceEntry({
    required this.name,
    required this.stableId,
    required this.isDirectory,
    this.directory,
    this.sourceRef,
    this.sizeBytes,
    this.modifiedAt,
    this.serverTitleId,
    this.seasonNumber,
    this.episodeNumber,
    this.legacyResumeKey,
    this.isStrm = false,
  });

  final String name;
  final String stableId;
  final bool isDirectory;
  final SourceDirectory? directory;
  final MediaSourceRef? sourceRef;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final String? serverTitleId;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? legacyResumeKey;
  final bool isStrm;
}

class ListingPage {
  const ListingPage({required this.entries, this.nextCursor});

  final List<SourceEntry> entries;
  final String? nextCursor;
}

abstract interface class LibrarySourceAdapter {
  String get sourceId;

  Future<ListingPage> list(SourceDirectory directory, {String? cursor});

  Future<VideoItem> resolvePlayable(MediaFile file);
}

abstract interface class SmallTextLibrarySourceAdapter {
  Future<String?> readSmallText(MediaFile file, {int maxBytes = 65536});
}

class DiscoveryContext {
  const DiscoveryContext({required this.directoryNames, this.rootId});

  final List<String> directoryNames;
  final String? rootId;
}

class MatchResult {
  const MatchResult({required this.file, this.title, this.episode});

  final MediaFile file;
  final MediaTitle? title;
  final LibraryEpisode? episode;
}

abstract interface class MetadataResolver {
  Future<MatchResult> resolve(MediaFile file, DiscoveryContext context);
}

T _enumByName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

DateTime? _dateFromMs(Object? value) =>
    value is num ? DateTime.fromMillisecondsSinceEpoch(value.toInt()) : null;

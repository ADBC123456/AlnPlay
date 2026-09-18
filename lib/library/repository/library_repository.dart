import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/library_models.dart';

class ScanBatch {
  const ScanBatch({
    required this.rootId,
    required this.generation,
    this.files = const [],
    this.titles = const [],
    this.episodes = const [],
    this.isStart = false,
    this.isRootComplete = false,
    this.seenFileIds = const {},
  });

  final String rootId;
  final String generation;
  final List<MediaFile> files;
  final List<MediaTitle> titles;
  final List<LibraryEpisode> episodes;
  final bool isStart;
  final bool isRootComplete;
  final Set<String> seenFileIds;
}

class LibraryQuery {
  const LibraryQuery({required this.text});

  final String text;
}

class LibrarySearchHit {
  const LibrarySearchHit({this.title, this.episode, this.file, this.matchHint});

  final MediaTitle? title;
  final LibraryEpisode? episode;
  final MediaFile? file;
  final String? matchHint;
}

class SearchResult {
  const SearchResult(this.hits);

  final List<LibrarySearchHit> hits;
}

class LibrarySnapshot {
  const LibrarySnapshot({
    this.titles = const {},
    this.episodes = const {},
    this.files = const {},
    this.overrides = const {},
    this.damagedSourceIds = const {},
  });

  final Map<String, MediaTitle> titles;
  final Map<String, LibraryEpisode> episodes;
  final Map<String, MediaFile> files;
  final Map<String, LibraryOverride> overrides;
  final Set<String> damagedSourceIds;

  List<MediaFile> filesForTitle(String titleId) => files.values
      .where((file) => file.titleId == titleId)
      .toList(growable: false);

  List<MediaFile> versionsForEpisode(String episodeId) => files.values
      .where(
        (file) =>
            file.episodeId == episodeId &&
            file.availability != MediaAvailability.missing,
      )
      .toList(growable: false);

  int availableEpisodeCount(String titleId) => files.values
      .where(
        (file) =>
            file.titleId == titleId &&
            file.episodeId != null &&
            file.availability != MediaAvailability.missing,
      )
      .map((file) => file.episodeId)
      .toSet()
      .length;
}

abstract interface class LibraryRepository {
  Stream<LibrarySnapshot> watch();

  Future<LibrarySnapshot> snapshot();

  Future<void> applyScanBatch(ScanBatch batch);

  Future<void> applyOverrides(List<LibraryOverride> overrides);

  Future<SearchResult> search(LibraryQuery query);
}

class JsonLibraryRepository implements LibraryRepository {
  JsonLibraryRepository({this.storageDirectory});

  static const int schemaVersion = 1;
  static const String _manifestName = 'manifest.json';
  static const String _catalogName = 'catalog.json';

  Directory? storageDirectory;
  final StreamController<LibrarySnapshot> _changes =
      StreamController<LibrarySnapshot>.broadcast();
  Future<void> _writeTail = Future<void>.value();
  LibrarySnapshot? _snapshot;
  final Map<String, String> _rootGenerations = {};

  @override
  Stream<LibrarySnapshot> watch() async* {
    yield await snapshot();
    yield* _changes.stream;
  }

  @override
  Future<LibrarySnapshot> snapshot() async {
    await _writeTail;
    return _snapshot ??= await _readSnapshot();
  }

  Future<void> clearAll() => _enqueue(() async {
    const empty = LibrarySnapshot();
    await _persist(empty);
    // The recovery copy must not resurrect the deleted catalog on restart.
    await _persist(empty);
    final directory = await _indexDirectory();
    await for (final entity in directory.list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (entity is File &&
          name.startsWith('source_') &&
          (name.endsWith('.json') ||
              name.endsWith('.json.bak') ||
              name.endsWith('.json.tmp'))) {
        await entity.delete();
      }
    }
    _rootGenerations.clear();
    _snapshot = empty;
    _changes.add(empty);
  });

  @override
  Future<void> applyScanBatch(ScanBatch batch) => _enqueue(() async {
    final current = _snapshot ??= await _readSnapshot();
    if (batch.isStart) {
      _rootGenerations[batch.rootId] = batch.generation;
    }
    if (_rootGenerations[batch.rootId] != batch.generation) return;

    final titles = Map<String, MediaTitle>.of(current.titles);
    final episodes = Map<String, LibraryEpisode>.of(current.episodes);
    final files = Map<String, MediaFile>.of(current.files);
    for (final title in batch.titles) {
      titles[title.id] = title;
    }
    for (final episode in batch.episodes) {
      episodes[episode.id] = episode;
    }
    for (final discovered in batch.files) {
      final previous = files[discovered.id];
      final isMetadataResult =
          discovered.identificationState != MetadataState.unresolved;
      if (previous != null &&
          isMetadataResult &&
          previous.matchRevision != discovered.matchRevision) {
        // A manual correction or newer identification won the race while this
        // request was in flight. Never let its stale result replace it.
        continue;
      }
      final keepPreviousState =
          previous != null &&
          discovered.titleId == null &&
          discovered.identificationState == MetadataState.unresolved;
      final keepPreviousBinding =
          previous?.titleId != null &&
          discovered.titleId == null &&
          const {
            MetadataState.unresolved,
            MetadataState.noApiKey,
            MetadataState.offline,
            MetadataState.failed,
          }.contains(discovered.identificationState);
      final roots = <String>{
        ...?previous?.rootIds,
        ...discovered.rootIds,
        batch.rootId,
      };
      files[discovered.id] = discovered.copyWith(
        rootIds: roots,
        titleId: keepPreviousBinding ? previous!.titleId : discovered.titleId,
        episodeId: keepPreviousBinding
            ? previous!.episodeId
            : discovered.episodeId,
        matchOrigin: keepPreviousBinding
            ? previous!.matchOrigin
            : discovered.matchOrigin,
        identificationState: keepPreviousState
            ? previous.identificationState
            : discovered.identificationState,
        availability: MediaAvailability.available,
        matchRevision: keepPreviousBinding
            ? previous!.matchRevision
            : discovered.matchRevision,
      );
    }

    if (batch.isRootComplete) {
      for (final entry in files.entries.toList()) {
        final file = entry.value;
        if (!file.rootIds.contains(batch.rootId) ||
            batch.seenFileIds.contains(file.id)) {
          continue;
        }
        final roots = Set<String>.of(file.rootIds)..remove(batch.rootId);
        files[entry.key] = file.copyWith(
          rootIds: roots,
          availability: roots.isEmpty
              ? MediaAvailability.missing
              : file.availability,
        );
      }
      _rootGenerations.remove(batch.rootId);
    }

    _snapshot = LibrarySnapshot(
      titles: Map.unmodifiable(titles),
      episodes: Map.unmodifiable(episodes),
      files: Map.unmodifiable(files),
      overrides: current.overrides,
      damagedSourceIds: current.damagedSourceIds,
    );
    await _persist(_snapshot!);
    _changes.add(_snapshot!);
  });

  @override
  Future<void> applyOverrides(List<LibraryOverride> overrides) => _enqueue(
    () async {
      final current = _snapshot ??= await _readSnapshot();
      final nextOverrides = Map<String, LibraryOverride>.of(current.overrides);
      final files = Map<String, MediaFile>.of(current.files);
      for (final override in overrides) {
        final file = files[override.fileId];
        final nextRevision = (file?.matchRevision ?? 0) + 1;
        final versionedOverride = LibraryOverride(
          fileId: override.fileId,
          pinnedTitleId: override.pinnedTitleId,
          seasonNumber: override.seasonNumber,
          episodeNumber: override.episodeNumber,
          revision: nextRevision,
        );
        nextOverrides[override.fileId] = versionedOverride;
        if (file == null) continue;
        final episodeId = override.episodeNumber == null
            ? null
            : '${override.pinnedTitleId}:s${override.seasonNumber ?? 'unknown'}'
                  ':e${override.episodeNumber}';
        files[override.fileId] = file.copyWith(
          titleId: override.pinnedTitleId,
          episodeId: episodeId,
          matchOrigin: MatchOrigin.manual,
          matchRevision: nextRevision,
        );
      }
      _snapshot = LibrarySnapshot(
        titles: current.titles,
        episodes: current.episodes,
        files: Map.unmodifiable(files),
        overrides: Map.unmodifiable(nextOverrides),
        damagedSourceIds: current.damagedSourceIds,
      );
      await _persist(_snapshot!);
      _changes.add(_snapshot!);
    },
  );

  @override
  Future<SearchResult> search(LibraryQuery query) async {
    final data = await snapshot();
    final needle = query.text.trim().toLowerCase();
    if (needle.isEmpty) return const SearchResult([]);
    final hits = <LibrarySearchHit>[];
    final matchedTitles = <String>{};
    for (final title in data.titles.values) {
      if (_contains(title.displayTitle, needle) ||
          _contains(title.originalTitle, needle)) {
        hits.add(LibrarySearchHit(title: title));
        matchedTitles.add(title.id);
      }
    }
    for (final episode in data.episodes.values) {
      if (!_contains(episode.displayName, needle)) continue;
      hits.add(
        LibrarySearchHit(
          title: data.titles[episode.titleId],
          episode: episode,
          matchHint: _episodeHint(episode),
        ),
      );
    }
    for (final file in data.files.values) {
      if (!_contains(file.originalFileName, needle)) continue;
      hits.add(
        LibrarySearchHit(
          title: file.titleId == null ? null : data.titles[file.titleId],
          episode: file.episodeId == null
              ? null
              : data.episodes[file.episodeId],
          file: file,
          matchHint: file.episodeId == null
              ? file.originalFileName
              : _episodeHint(data.episodes[file.episodeId]),
        ),
      );
    }
    return SearchResult(hits);
  }

  Future<void> _enqueue(Future<void> Function() mutation) {
    final operation = _writeTail.then((_) => mutation());
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _writeTail = settled;
    return () async {
      try {
        await operation;
      } finally {
        await settled;
      }
    }();
  }

  Future<Directory> _indexDirectory() async {
    if (storageDirectory != null) {
      await storageDirectory!.create(recursive: true);
      return storageDirectory!;
    }
    final support = await getApplicationSupportDirectory();
    storageDirectory = Directory(
      '${support.path}${Platform.pathSeparator}library',
    );
    await storageDirectory!.create(recursive: true);
    return storageDirectory!;
  }

  Future<LibrarySnapshot> _readSnapshot() async {
    final directory = await _indexDirectory();
    final damaged = <String>{};
    final catalog = await _readJsonWithBackup(
      File('${directory.path}${Platform.pathSeparator}$_catalogName'),
    );
    final manifest = await _readJsonWithBackup(
      File('${directory.path}${Platform.pathSeparator}$_manifestName'),
    );
    if (catalog == null || manifest == null) return const LibrarySnapshot();
    if ((manifest['schemaVersion'] as num?)?.toInt() != schemaVersion) {
      return const LibrarySnapshot();
    }

    final titles = _decodeMap(
      catalog['titles'],
      (json) => MediaTitle.fromJson(json),
    );
    final episodes = _decodeMap(
      catalog['episodes'],
      (json) => LibraryEpisode.fromJson(json),
    );
    final overrides = _decodeMap(
      catalog['overrides'],
      (json) => LibraryOverride.fromJson(json),
    );
    final files = <String, MediaFile>{};
    final shards = (manifest['sourceShards'] as Map? ?? const {})
        .cast<String, dynamic>();
    for (final entry in shards.entries) {
      final shard = await _readJsonWithBackup(
        File('${directory.path}${Platform.pathSeparator}${entry.value}'),
      );
      if (shard == null) {
        damaged.add(entry.key);
        continue;
      }
      files.addAll(
        _decodeMap(shard['files'], (json) => MediaFile.fromJson(json)),
      );
    }
    return LibrarySnapshot(
      titles: Map.unmodifiable(titles),
      episodes: Map.unmodifiable(episodes),
      files: Map.unmodifiable(files),
      overrides: Map.unmodifiable(overrides),
      damagedSourceIds: Set.unmodifiable(damaged),
    );
  }

  Future<void> _persist(LibrarySnapshot snapshot) async {
    final directory = await _indexDirectory();
    final bySource = <String, List<MediaFile>>{};
    for (final file in snapshot.files.values) {
      (bySource[file.sourceRef.sourceId] ??= []).add(file);
    }
    final shards = <String, String>{};
    for (final entry in bySource.entries) {
      final encoded = base64Url
          .encode(utf8.encode(entry.key))
          .replaceAll('=', '');
      final name = 'source_$encoded.json';
      shards[entry.key] = name;
      await _atomicWrite(
        File('${directory.path}${Platform.pathSeparator}$name'),
        {
          'schemaVersion': schemaVersion,
          'sourceId': entry.key,
          'files': {for (final file in entry.value) file.id: file.toJson()},
        },
      );
    }
    await _atomicWrite(
      File('${directory.path}${Platform.pathSeparator}$_catalogName'),
      {
        'schemaVersion': schemaVersion,
        'titles': {
          for (final title in snapshot.titles.values) title.id: title.toJson(),
        },
        'episodes': {
          for (final episode in snapshot.episodes.values)
            episode.id: episode.toJson(),
        },
        'overrides': {
          for (final override in snapshot.overrides.values)
            override.fileId: override.toJson(),
        },
      },
    );
    await _atomicWrite(
      File('${directory.path}${Platform.pathSeparator}$_manifestName'),
      {'schemaVersion': schemaVersion, 'sourceShards': shards},
    );
  }

  Future<void> _atomicWrite(File target, Map<String, dynamic> json) async {
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    await temporary.writeAsString(jsonEncode(json), flush: true);
    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
    } catch (_) {
      if (await backup.exists() && !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _readJsonWithBackup(File file) async {
    Future<Map<String, dynamic>?> read(File candidate) async {
      if (!await candidate.exists()) return null;
      try {
        return (jsonDecode(await candidate.readAsString()) as Map)
            .cast<String, dynamic>();
      } catch (_) {
        return null;
      }
    }

    final primary = await read(file);
    if (primary != null) return primary;
    final backup = await read(File('${file.path}.bak'));
    if (backup != null) {
      await _atomicWrite(file, backup);
      return backup;
    }
    return null;
  }

  static Map<String, T> _decodeMap<T>(
    Object? raw,
    T Function(Map<String, dynamic>) decode,
  ) {
    final result = <String, T>{};
    final map = (raw as Map? ?? const {}).cast<String, dynamic>();
    for (final entry in map.entries) {
      try {
        result[entry.key] = decode(
          (entry.value as Map).cast<String, dynamic>(),
        );
      } catch (_) {}
    }
    return result;
  }

  static bool _contains(String? value, String needle) =>
      value?.toLowerCase().contains(needle) ?? false;

  static String? _episodeHint(LibraryEpisode? episode) {
    if (episode == null) return null;
    final season = episode.seasonNumber;
    return season == null
        ? 'E${episode.episodeNumber}'
        : 'S${season.toString().padLeft(2, '0')}'
              'E${episode.episodeNumber.toString().padLeft(2, '0')}';
  }

  @visibleForTesting
  Future<void> close() => _changes.close();
}

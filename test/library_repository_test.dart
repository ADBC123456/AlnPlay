import 'dart:io';

import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/repository/library_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late JsonLibraryRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dream_library_test_');
    repository = JsonLibraryRepository(storageDirectory: directory);
  });

  tearDown(() async {
    await repository.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('aggregates one title and episode across source versions', () async {
    const title = MediaTitle(
      id: 'tmdb:tv:42',
      kind: MediaTitleKind.tv,
      tmdbId: 42,
      displayTitle: 'Example Show',
    );
    const episode = LibraryEpisode(
      id: 'tmdb:tv:42:s1:e1',
      titleId: 'tmdb:tv:42',
      seasonNumber: 1,
      episodeNumber: 1,
      displayName: 'Pilot',
    );
    await repository.applyScanBatch(
      const ScanBatch(rootId: 'root-a', generation: '1', isStart: true),
    );
    await repository.applyScanBatch(
      ScanBatch(
        rootId: 'root-a',
        generation: '1',
        titles: const [title],
        episodes: const [episode],
        files: [
          _file(
            id: 'webdav:file-1',
            rootId: 'root-a',
            sourceId: 'webdav:home',
            titleId: title.id,
            episodeId: episode.id,
          ),
          _file(
            id: 'jellyfin:file-1',
            rootId: 'root-a',
            sourceId: 'jellyfin:living-room',
            titleId: title.id,
            episodeId: episode.id,
          ),
        ],
      ),
    );
    final data = await repository.snapshot();
    expect(data.titles, hasLength(1));
    expect(data.availableEpisodeCount(title.id), 1);
    expect(data.versionsForEpisode(episode.id), hasLength(2));
  });

  test(
    'completed overlapping-root scan removes only its own reference',
    () async {
      await repository.applyScanBatch(
        const ScanBatch(rootId: 'root-a', generation: '1', isStart: true),
      );
      await repository.applyScanBatch(
        ScanBatch(
          rootId: 'root-a',
          generation: '1',
          files: [
            _file(id: 'files:same', rootId: 'root-a', sourceId: 'files:device'),
          ],
        ),
      );
      await repository.applyScanBatch(
        const ScanBatch(
          rootId: 'root-a',
          generation: '1',
          isRootComplete: true,
        ),
      );
      await repository.applyScanBatch(
        const ScanBatch(rootId: 'root-b', generation: '2', isStart: true),
      );
      await repository.applyScanBatch(
        ScanBatch(
          rootId: 'root-b',
          generation: '2',
          files: [
            _file(id: 'files:same', rootId: 'root-b', sourceId: 'files:device'),
          ],
        ),
      );
      await repository.applyScanBatch(
        const ScanBatch(
          rootId: 'root-b',
          generation: '2',
          isRootComplete: true,
          seenFileIds: {'files:same'},
        ),
      );

      await repository.applyScanBatch(
        const ScanBatch(rootId: 'root-a', generation: '3', isStart: true),
      );
      await repository.applyScanBatch(
        const ScanBatch(
          rootId: 'root-a',
          generation: '3',
          isRootComplete: true,
        ),
      );
      final file = (await repository.snapshot()).files['files:same']!;
      expect(file.rootIds, {'root-b'});
      expect(file.availability, MediaAvailability.available);
    },
  );

  test(
    'failed or unfinished generation never marks old files missing',
    () async {
      await repository.applyScanBatch(
        const ScanBatch(rootId: 'root', generation: '1', isStart: true),
      );
      await repository.applyScanBatch(
        ScanBatch(
          rootId: 'root',
          generation: '1',
          files: [
            _file(id: 'files:old', rootId: 'root', sourceId: 'files:device'),
          ],
        ),
      );
      await repository.applyScanBatch(
        const ScanBatch(
          rootId: 'root',
          generation: '1',
          isRootComplete: true,
          seenFileIds: {'files:old'},
        ),
      );
      await repository.applyScanBatch(
        const ScanBatch(rootId: 'root', generation: '2', isStart: true),
      );

      final file = (await repository.snapshot()).files['files:old']!;
      expect(file.availability, MediaAvailability.available);
      expect(file.rootIds, contains('root'));
    },
  );

  test(
    'searches title, original title, episode and filename offline',
    () async {
      const title = MediaTitle(
        id: 'tmdb:tv:1',
        kind: MediaTitleKind.tv,
        tmdbId: 1,
        displayTitle: 'The Demon Hunter',
        originalTitle: '沧元图',
      );
      const episode = LibraryEpisode(
        id: 'tmdb:tv:1:s0:e1',
        titleId: 'tmdb:tv:1',
        seasonNumber: 0,
        episodeNumber: 1,
        displayName: '特别篇',
      );
      await repository.applyScanBatch(
        const ScanBatch(rootId: 'root', generation: '1', isStart: true),
      );
      await repository.applyScanBatch(
        ScanBatch(
          rootId: 'root',
          generation: '1',
          titles: const [title],
          episodes: const [episode],
          files: [
            _file(
              id: 'files:special',
              rootId: 'root',
              sourceId: 'files:device',
              titleId: title.id,
              episodeId: episode.id,
              fileName: 'Bonus.S00E01.mkv',
            ),
          ],
        ),
      );

      expect(
        (await repository.search(const LibraryQuery(text: '沧元'))).hits,
        hasLength(1),
      );
      expect(
        (await repository.search(
          const LibraryQuery(text: '特别'),
        )).hits.single.matchHint,
        'S00E01',
      );
      expect(
        (await repository.search(
          const LibraryQuery(text: 'bonus'),
        )).hits.single.file?.id,
        'files:special',
      );
    },
  );

  test(
    'persists source shards and restores a corrupt primary from backup',
    () async {
      await repository.applyScanBatch(
        const ScanBatch(rootId: 'root', generation: '1', isStart: true),
      );
      await repository.applyScanBatch(
        ScanBatch(
          rootId: 'root',
          generation: '1',
          files: [
            _file(id: 'files:one', rootId: 'root', sourceId: 'files:device'),
          ],
        ),
      );
      // A second persistence pass creates .bak files containing valid JSON.
      await repository.applyScanBatch(
        ScanBatch(
          rootId: 'root',
          generation: '1',
          files: [
            _file(id: 'files:two', rootId: 'root', sourceId: 'files:device'),
          ],
        ),
      );
      await repository.close();

      final shard = directory.listSync().whereType<File>().singleWhere(
        (file) => file.path.contains('source_') && !file.path.endsWith('.bak'),
      );
      await shard.writeAsString('{broken');
      final restored = JsonLibraryRepository(storageDirectory: directory);
      final data = await restored.snapshot();
      expect(data.files, contains('files:one'));
      expect(data.damagedSourceIds, isEmpty);
      await restored.close();
      repository = JsonLibraryRepository(storageDirectory: directory);
    },
  );

  test('manual override revision rejects stale metadata result', () async {
    await repository.applyScanBatch(
      const ScanBatch(rootId: 'root', generation: '1', isStart: true),
    );
    await repository.applyScanBatch(
      ScanBatch(
        rootId: 'root',
        generation: '1',
        files: [
          _file(id: 'files:race', rootId: 'root', sourceId: 'files:device'),
        ],
      ),
    );
    await repository.applyOverrides(const [
      LibraryOverride(fileId: 'files:race', pinnedTitleId: 'tmdb:tv:manual'),
    ]);
    final stale = _file(
      id: 'files:race',
      rootId: 'root',
      sourceId: 'files:device',
      titleId: 'tmdb:tv:stale',
    ).copyWith(identificationState: MetadataState.matched);
    await repository.applyScanBatch(
      ScanBatch(rootId: 'root', generation: '1', files: [stale]),
    );

    final file = (await repository.snapshot()).files['files:race']!;
    expect(file.titleId, 'tmdb:tv:manual');
    expect(file.matchOrigin, MatchOrigin.manual);
    expect(file.matchRevision, 1);
  });

  test('transient metadata failure preserves an existing binding', () async {
    await repository.applyScanBatch(
      const ScanBatch(rootId: 'root', generation: '1', isStart: true),
    );
    await repository.applyScanBatch(
      ScanBatch(
        rootId: 'root',
        generation: '1',
        files: [
          _file(
            id: 'files:known',
            rootId: 'root',
            sourceId: 'files:device',
            titleId: 'tmdb:movie:1',
          ).copyWith(identificationState: MetadataState.matched),
        ],
      ),
    );
    await repository.applyScanBatch(
      ScanBatch(
        rootId: 'root',
        generation: '1',
        files: [
          _file(
            id: 'files:known',
            rootId: 'root',
            sourceId: 'files:device',
          ).copyWith(identificationState: MetadataState.offline),
        ],
      ),
    );

    final file = (await repository.snapshot()).files['files:known']!;
    expect(file.titleId, 'tmdb:movie:1');
    expect(file.identificationState, MetadataState.offline);
  });
}

MediaFile _file({
  required String id,
  required String rootId,
  required String sourceId,
  String? titleId,
  String? episodeId,
  String fileName = 'video.mkv',
}) => MediaFile(
  id: id,
  rootIds: {rootId},
  sourceRef: MediaSourceRef(
    sourceId: sourceId,
    sourceType: sourceId.split(':').first,
    path: '/$fileName',
  ),
  originalFileName: fileName,
  titleId: titleId,
  episodeId: episodeId,
  matchOrigin: titleId == null ? null : MatchOrigin.automatic,
  availability: MediaAvailability.available,
  legacyResumeKey: id,
);

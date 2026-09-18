import 'dart:convert';
import 'dart:io';

import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/repository/library_repository.dart';
import 'package:dream_player/library/unified_library_service.dart';
import 'package:dream_player/services/library_folders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Clearing the media library runs on real file IO, so it lives outside the
/// widget-test clock (a fake clock never completes the index rewrite).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LibraryFolder folder() => LibraryFolder(
    id: 'tree:test-folder',
    name: 'Test Show',
    path: 'tree:test-folder',
    addedAt: DateTime.now(),
  );

  test('clearLibrary drops folders, index and scan timestamps', () async {
    final directory = await Directory.systemTemp.createTemp('aln_clear_');
    addTearDown(() => directory.delete(recursive: true));
    final service = UnifiedLibraryService.instance;
    service.repository.storageDirectory = directory;

    SharedPreferences.setMockInitialValues({
      'dreamplayer.appLanguage': 'zh',
      'dreamplayer.libraryFolders': jsonEncode([folder().toJson()]),
      'dreamplayer.libraryScanTimes': const ['folder|1'],
    });
    await service.repository.applyScanBatch(
      const ScanBatch(rootId: 'root', generation: '1', isStart: true),
    );
    await service.repository.applyScanBatch(
      ScanBatch(
        rootId: 'root',
        generation: '1',
        files: [
          const MediaFile(
            id: 'file-1',
            rootIds: {'root'},
            sourceRef: MediaSourceRef(
              sourceId: 'files:device',
              sourceType: 'files',
              path: '/video/one.mkv',
            ),
            originalFileName: 'one.mkv',
            legacyResumeKey: '/video/one.mkv',
          ),
        ],
      ),
    );
    expect((await service.repository.snapshot()).files, isNotEmpty);

    await service.clearLibrary();

    expect(await LibraryFoldersStore.load(), isEmpty);
    expect((await service.repository.snapshot()).files, isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getStringList(
        'dreamplayer.libraryScanTimes',
      ),
      isNull,
    );
    expect(
      (await SharedPreferences.getInstance()).getString(
        'dreamplayer.appLanguage',
      ),
      'zh',
    );
  });
}

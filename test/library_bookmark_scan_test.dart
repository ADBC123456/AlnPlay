import 'dart:io';

import 'package:dream_player/library/scanner/library_scanner.dart';
import 'package:dream_player/library/unified_library_service.dart';
import 'package:dream_player/services/library_folders.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a newly bookmarked folder is scanned into the library', () async {
    final directory = await Directory.systemTemp.createTemp('aln_bookmark_scan_');
    addTearDown(() => directory.delete(recursive: true));
    SharedPreferences.setMockInitialValues({});
    final service = UnifiedLibraryService.instance;
    service.repository.storageDirectory = directory;

    const channel = MethodChannel('dreamplayer/files');
    final messenger = TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listDirectory') {
        return <Map<String, Object?>>[
          {
            'name': 'Show.S01E01.mkv',
            'path': 'tree:test-folder/Show.S01E01.mkv',
            'isDirectory': false,
            'size': 2048,
          },
        ];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await service.refresh([
      LibraryFolder(
        id: 'tree:test-folder',
        name: 'Test Show',
        path: 'tree:test-folder',
        addedAt: DateTime.now(),
      ),
    ]);

    final snapshot = await service.repository.snapshot();
    expect(
      snapshot.files.values.map((file) => file.originalFileName),
      contains('Show.S01E01.mkv'),
    );
    expect(service.progressByRoot['tree:test-folder']?.state, ScanState.complete);
  });
}

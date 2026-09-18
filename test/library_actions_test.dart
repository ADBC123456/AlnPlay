import 'dart:convert';

import 'package:dream_player/app.dart';
import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/continue_watching.dart';
import 'package:dream_player/services/library_folders.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Interactions behind the 0.4.5 merge: collapsible settings groups and the
/// confirmed "clear" actions on the library screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LibraryFolder folder() => LibraryFolder(
    id: 'tree:test-folder',
    name: 'Test Show',
    path: 'tree:test-folder',
    addedAt: DateTime.now(),
  );

  testWidgets('settings groups collapse and expand', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const AlnPlayApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('主题'), findsOneWidget);

    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(find.text('主题'), findsNothing);

    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(find.text('主题'), findsOneWidget);
  });

  testWidgets('clear continue watching asks first and then empties the shelf', (
    tester,
  ) async {
    final entry = ContinueWatchingEntry(
      video: const VideoItem(
        id: 'recent-one',
        title: 'Saved Film',
        path: '/video/Saved.Film.mkv',
        duration: Duration(minutes: 2),
      ),
      position: const Duration(seconds: 45),
      updatedAt: DateTime.now(),
    );
    SharedPreferences.setMockInitialValues({
      'dreamplayer.continueWatching': jsonEncode([entry.toJson()]),
    });

    await tester.pumpWidget(const AlnPlayApp());
    await tester.pumpAndSettle();
    expect(find.text('Saved Film'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空继续观看'));
    await tester.pumpAndSettle();
    expect(find.text('清空继续观看？'), findsOneWidget);

    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();

    expect(await ContinueWatchingStore.load(), isEmpty);
    expect(find.text('Saved Film'), findsNothing);
  });

  testWidgets('clear library waits for confirmation and keeps data on cancel', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'dreamplayer.libraryFolders': jsonEncode([folder().toJson()]),
    });

    await tester.pumpWidget(const AlnPlayApp());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.more_vert), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空媒体库'));
    await tester.pumpAndSettle();
    expect(find.text('清空媒体库？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('清空媒体库？'), findsNothing);
    expect(await LibraryFoldersStore.load(), hasLength(1));

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空媒体库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    // Pump past the dialog's exit transition: the confirmed action starts the
    // clear and the toolbar switches to its progress state. The index rewrite
    // itself is file IO, which only the real-event-loop test below can drive.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });
}

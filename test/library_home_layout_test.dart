import 'package:dream_player/app.dart';
import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/repository/library_repository.dart';
import 'package:dream_player/library/unified_library_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [
    const Size(360, 800),
    const Size(430, 900),
    const Size(800, 360),
  ]) {
    testWidgets(
      'populated shelves keep readable posters at $size with large text',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final library = UnifiedLibraryService.instance;
        final previous = library.snapshot;
        addTearDown(() => library.snapshot = previous);
        await tester.pumpWidget(const AlnPlayApp());
        await tester.pumpAndSettle();
        library.snapshot = LibrarySnapshot(
          titles: {
            for (var i = 0; i < 8; i++)
              'tv$i': MediaTitle(
                id: 'tv$i',
                kind: MediaTitleKind.tv,
                tmdbId: i,
                displayTitle: '凡人修仙传特别篇$i',
                releaseDate: '2020-07-25',
                rating: 8.5,
              ),
          },
        );
        await tester.tap(find.text('资源库'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('媒体库'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('电视剧'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        // Keep the section heading below the pinned app bar. Scrolling to a
        // poster itself also scrolls its horizontal viewport to offset zero.
        await tester.drag(
          find.byType(CustomScrollView).first,
          const Offset(0, 100),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (size.width < 600) {
          final visibleColumns = ((size.width - 24) / (88 + 8)).floor();
          final first = tester.getRect(find.byKey(const ValueKey('tv0')));
          final lastVisible = tester.getRect(
            find.byKey(ValueKey('tv${visibleColumns - 1}')),
          );
          expect(first.top, lastVisible.top);
          expect(first.left, greaterThanOrEqualTo(16));
          expect(lastVisible.right, lessThanOrEqualTo(size.width - 15));
          expect(first.width, greaterThanOrEqualTo(88));
        }
        await tester.tap(find.text('电视剧'));
        await tester.pumpAndSettle();
        expect(find.byType(GridView), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/widgets/episode_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _episodes = List.generate(
  206,
  (index) => LibraryEpisode(
    id: 'e${index + 1}',
    titleId: 'show',
    seasonNumber: 1,
    episodeNumber: index + 1,
    displayName: 'Episode ${index + 1}',
  ),
);

void main() {
  for (final size in [
    const Size(320, 700),
    const Size(375, 812),
    const Size(600, 834),
    const Size(834, 1194),
    const Size(1194, 834),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'picker positions episode 74 and fits $size at scale $scale',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: scale == 1 ? Brightness.light : Brightness.dark,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showModalBottomSheet<LibraryEpisode>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      constraints: const BoxConstraints(maxWidth: 820),
                      builder: (_) => EpisodePickerSheet(
                        episodes: _episodes,
                        season: 1,
                        currentEpisodeId: 'e74',
                        total: 206,
                        isAvailable: (episode) => episode.episodeNumber != 75,
                        positionFor: (episode) => episode.episodeNumber == 74
                            ? const Duration(minutes: 9, seconds: 21)
                            : null,
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('picker-e74')).hitTestable(),
            findsOneWidget,
          );
          expect(find.widgetWithText(ChoiceChip, '51–100'), findsOneWidget);
          expect(
            tester
                .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '51–100'))
                .selected,
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('关闭'));
          await tester.pumpAndSettle();
          expect(find.text('Open'), findsOneWidget);
        },
      );
    }
  }
  testWidgets('unavailable cards cannot return a selection', (tester) async {
    LibraryEpisode? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<LibraryEpisode>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => EpisodePickerSheet(
                    episodes: [_episodes[73], _episodes[74]],
                    season: 1,
                    currentEpisodeId: 'e74',
                    isAvailable: (episode) => episode.id != 'e75',
                    positionFor: (_) => null,
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('picker-e75')));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byTooltip('关闭'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('picker-e74')));
    await tester.pumpAndSettle();
    expect(result?.id, 'e74');
  });
}

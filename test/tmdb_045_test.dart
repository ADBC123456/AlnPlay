import 'package:dream_player/services/tmdb_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('movie part numbers do not become episode numbers from ancestors', () {
    final parsed = ParsedFileName.parseWithAncestors('Dune.Part.2.2024.mkv', ['Movies']);
    expect(parsed.title, 'Dune Part 2');
    expect(parsed.hasMovieSequelPattern, isTrue);
    expect(parsed.isEpisode, isFalse);
    expect(parsed.seriesName, isNull);
    expect(ParsedFileName.parse('Arrival.2016.mkv', parentFolderName: 'Movies').seriesName, isNull);
  });

  test('explicit live action marker uses actual TMDB animation genre', () {
    final parsed = ParsedFileName.parseWithAncestors('S01E01.mkv', ['Kakegurui Twin (Live Action)', 'Season 1']);
    expect(parsed.liveAction, isTrue);
    expect(parsed.seriesName, 'Kakegurui Twin');
    final api = TmdApi();
    const animated = TmdMovie(id: 1, title: 'Kakegurui Twin', kind: TmdKind.tv, genreIds: [16]);
    const live = TmdMovie(id: 2, title: 'Kakegurui Twin', kind: TmdKind.tv, genreIds: [18]);
    expect(api.scoreCandidate(live, parsed), greaterThan(api.scoreCandidate(animated, parsed)));
    expect(TmdMovie.fromMetaJson(animated.toJson()).genreIds, [16]);
  });

  test('official arc names survive restart without prefix season guesses', () {
    final details = TmdDetails.fromJson({
      'name': 'Example',
      'seasons': [{'season_number': 3, 'name': 'Final Arc'}],
    }, kind: TmdKind.tv);
    final meta = TmdMeta.fromJson(TmdMeta(movie: const TmdMovie(id: 1, title: 'Example'), details: details).toJson());
    expect(meta.details!.seasonForFolder('Final.Arc'), 3);
    expect(meta.details!.seasonForFolder('Final Arc Movie'), isNull);
    expect(meta.details!.seasonForFolder('Unknown Special'), isNull);
  });
}

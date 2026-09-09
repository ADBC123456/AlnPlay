import 'package:dream_player/library/models/library_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MediaTitle title(List<String> genres, {String name = 'Neutral title'}) =>
      MediaTitle(
        id: name,
        kind: MediaTitleKind.tv,
        tmdbId: 1,
        displayTitle: name,
        genres: genres,
      );

  test('animation grouping relies on explicit metadata genres', () {
    expect(title(['Animation', 'Action']).isAnimation, isTrue);
    expect(title(['动画']).isAnimation, isTrue);
    expect(title(['動畫']).isAnimation, isTrue);
    expect(title(['アニメーション']).isAnimation, isTrue);
    expect(title(['Anime']).isAnimation, isTrue);
  });

  test('animation grouping does not guess from a title or unrelated genre', () {
    expect(title(['Drama'], name: 'Some Anime Folder').isAnimation, isFalse);
    expect(title(const []).isAnimation, isFalse);
    expect(title(['Animated adventure']).isAnimation, isFalse);
  });
}

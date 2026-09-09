import 'package:dream_player/screens/player_loading_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'MPV cache progress preserves known percentages, rejects unavailable',
    () {
      expect(parseMpvBufferingProgress('85'), .85);
      expect(parseMpvBufferingProgress('0'), 0);
      expect(parseMpvBufferingProgress('100'), 1);
      for (final raw in ['NaN', 'Infinity', '', 'no', '-1', '101']) {
        expect(parseMpvBufferingProgress(raw), isNull);
      }
    },
  );
  test('only the initial load of a video is detailed', () {
    final state = PlayerLoadingState()..begin('episode1');
    expect(state.showDetails, isTrue);
    state.markReady();
    expect(state.showDetails, isFalse);
    state.begin('episode1'); // seek, reconnect or subtitle reopen
    expect(state.showDetails, isFalse);
    state.begin('episode2');
    expect(state.showDetails, isTrue);
    state.markReady();
    state.begin('episode1'); // opening another episode is a new load
    expect(state.showDetails, isTrue);
  });
}

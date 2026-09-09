import 'package:dream_player/services/exo_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('non-finite progress never becomes a fabricated percentage', () {
    for (final value in [double.nan, double.infinity]) {
      expect(
        ExoPlayerEvent.fromMap({'bufferingProgress': value}).bufferingProgress,
        isNull,
      );
    }
  });
  test('reads and clamps buffering progress from native state', () {
    final event = ExoPlayerEvent.fromMap({
      'state': 2,
      'buffering': true,
      'bufferingProgress': 1.4,
    });
    expect(event.bufferingProgress, 1.0);
  });

  test('unknown platform buffering progress stays null', () {
    final event = ExoPlayerEvent.fromMap({'state': 2, 'buffering': true});
    expect(event.bufferingProgress, isNull);
  });
}

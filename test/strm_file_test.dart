import 'package:dream_player/library/source/strm_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads first HTTP URL after BOM, comments, and blank lines', () {
    final uri = parseExternalStrm(
      '\uFEFF# generated\r\n\r\nhttps://cdn.example/video.mkv?sig=short-lived\r\n',
    );
    expect(uri.host, 'cdn.example');
    expect(uri.queryParameters['sig'], 'short-lived');
  });

  test('v1 rejects non-http schemes and empty files', () {
    expect(
      () => parseExternalStrm('smb://server/share/movie.mkv'),
      throwsA(isA<StrmFormatException>()),
    );
    expect(
      () => parseExternalStrm('# no target'),
      throwsA(isA<StrmFormatException>()),
    );
  });

  test(
    'rejects playlists, nested targets, control bytes and oversized files',
    () {
      for (final input in [
        'https://cdn.example/a.mkv\nhttps://cdn.example/b.mkv',
        'https://cdn.example/nested.STRM?token=secret',
        'https:///no-host',
        'https://cdn.example/a\u0000.mkv',
        'https://cdn.example/a b.mkv',
        'https://cdn.example/${'x' * 65536}',
      ]) {
        expect(
          () => parseExternalStrm(input),
          throwsA(isA<StrmFormatException>()),
        );
      }
    },
  );

  test('supports encoded spaces and comments after the single target', () {
    expect(
      parseExternalStrm('; source\nhttps://cdn.example/a%20b.mkv\n# end').path,
      '/a%20b.mkv',
    );
  });
}

import 'dart:convert';

import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/strm_playback.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dreamplayer/webdav');
  final calls = <String>[];
  var target = 'https://cdn.example/first.mkv';

  setUp(() {
    calls.clear();
    target = 'https://cdn.example/first.mkv';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'listServers':
              return [
                {
                  'id': 'server',
                  'name': 'Test',
                  'url': 'https://dav.example/root',
                  'username': 'private-user',
                  'hasPassword': true,
                },
              ];
            case 'fetchUrl':
              return Uint8List.fromList(utf8.encode(target));
            default:
              fail('Unexpected WebDAV call: ${call.method}');
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'refreshes a WebDAV STRM target without requesting credentials',
    () async {
      const saved = VideoItem(
        id: 'stable-id',
        title: 'movie.strm',
        uri: 'https://expired.example/old.mkv',
        resumeKey: 'webdav_server/Movies/movie.strm',
        duration: Duration.zero,
        uriIsTransient: true,
      );

      final first = await refreshStrmPlayback(saved);
      target = 'https://cdn.example/second.mkv';
      final second = await refreshStrmPlayback(saved);

      expect(first.uri, 'https://cdn.example/first.mkv');
      expect(second.uri, 'https://cdn.example/second.mkv');
      expect(second.id, saved.id);
      expect(second.resumeKey, saved.resumeKey);
      expect(second.uriIsTransient, isTrue);
      expect(calls.where((method) => method == 'fetchUrl'), hasLength(2));
      expect(calls, isNot(contains('authorizationHeader')));
    },
  );
}

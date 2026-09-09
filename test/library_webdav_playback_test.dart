import 'dart:convert';

import 'package:dream_player/library/models/library_models.dart';
import 'package:dream_player/library/source/library_source_adapters.dart';
import 'package:dream_player/services/webdav_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dreamplayer/webdav');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => 'Basic test');
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  for (final name in ['沧元图.S01E01.mp4', '沧元图 100%.mkv', 'literal%20name.mkv']) {
    test(
      'resolves raw WebDAV filename $name without changing identity',
      () async {
        const server = WebDavServer(
          id: 'nas',
          name: 'NAS',
          url: 'https://example.test/dav',
          username: '',
          hasPassword: true,
        );
        final path = '/TV/沧元图/$name';
        final video = await WebDavLibrarySourceAdapter(server).resolvePlayable(
          MediaFile(
            id: 'file',
            rootIds: const {'root'},
            sourceRef: MediaSourceRef(
              sourceId: 'webdav:nas',
              sourceType: 'webdav',
              serverId: 'nas',
              path: path,
            ),
            originalFileName: name,
            legacyResumeKey: 'stable-resume',
          ),
        );
        expect(Uri.parse(video.uri!).pathSegments, ['dav', 'TV', '沧元图', name]);
        expect(video.resumeKey, 'stable-resume');
        expect(video.httpHeaders['Authorization'], 'Basic test');
      },
    );
  }

  test(
    'WebDAV STRM reads only the source and does not forward auth to target',
    () async {
      const server = WebDavServer(
        id: 'nas',
        name: 'NAS',
        url: 'https://example.test/dav',
        username: 'user',
        hasPassword: true,
      );
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            seen = call;
            expect(call.method, 'fetchUrl');
            return Uint8List.fromList(
              utf8.encode('https://media.example/video.mkv\n'),
            );
          });

      final video = await WebDavLibrarySourceAdapter(server).resolvePlayable(
        const MediaFile(
          id: 'webdav_nas/Movies/item.strm',
          rootIds: {'webdav:nas'},
          sourceRef: MediaSourceRef(
            sourceId: 'webdav:nas',
            sourceType: 'webdav',
            serverId: 'nas',
            path: '/Movies/item.strm',
          ),
          originalFileName: 'item.strm',
          legacyResumeKey: 'webdav_nas/Movies/item.strm',
          isStrm: true,
        ),
      );

      expect(seen!.arguments, containsPair('id', 'nas'));
      expect(seen!.arguments, containsPair('maxBytes', 65536));
      expect(
        seen!.arguments['url'],
        'https://example.test/dav/Movies/item.strm',
      );
      expect(video.uri, 'https://media.example/video.mkv');
      expect(video.uriIsTransient, isTrue);
      expect(video.resumeKey, 'webdav_nas/Movies/item.strm');
      expect(video.httpHeaders, isEmpty);
      expect(video.webdavServerId, isNull);
    },
  );

  test('WebDAV listing marks STRM entries as small text sources', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'listDirectory') {
            return [
              {
                'name': 'item.strm',
                'path': '/item.strm',
                'isDirectory': false,
                'size': 32,
              },
            ];
          }
          return null;
        });
    const server = WebDavServer(
      id: 'nas',
      name: 'NAS',
      url: 'https://example.test/dav',
      username: '',
      hasPassword: false,
    );
    final page = await WebDavLibrarySourceAdapter(server).list(
      const SourceDirectory(
        sourceId: 'webdav:nas',
        sourceType: 'webdav',
        identity: 'root',
        path: '/',
        serverId: 'nas',
      ),
    );
    expect(page.entries.single.isStrm, isTrue);
  });
}

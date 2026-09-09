import 'package:dream_player/models/video_item.dart';
import 'package:dream_player/services/continue_watching.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const video = VideoItem(
    id: 'webdav_0e417606-0deb-4af7-9d64-8914349788ba/Movies/Identity.2003.mkv',
    title: 'Identity.2003.mkv',
    uri: 'http://192.168.1.16:8080/dav/Movies/Identity.2003.mkv',
    resumeKey:
        'webdav_0e417606-0deb-4af7-9d64-8914349788ba/Movies/Identity.2003.mkv',
    duration: Duration.zero,
  );

  test('save skips sub-10s positions', () async {
    SharedPreferences.setMockInitialValues({});
    await ContinueWatchingStore.save(video, const Duration(seconds: 5));
    expect(await ContinueWatchingStore.load(), isEmpty);
  });

  test('save/load round-trips and dedups by key', () async {
    SharedPreferences.setMockInitialValues({});
    await ContinueWatchingStore.save(video, const Duration(minutes: 10));
    var entries = await ContinueWatchingStore.load();
    expect(entries, hasLength(1));
    expect(entries.first.position, const Duration(minutes: 10));

    await ContinueWatchingStore.save(video, const Duration(minutes: 11));
    entries = await ContinueWatchingStore.load();
    expect(entries, hasLength(1));
    expect(entries.first.position, const Duration(minutes: 11));
  });

  test('remove drops the entry', () async {
    SharedPreferences.setMockInitialValues({});
    await ContinueWatchingStore.save(video, const Duration(minutes: 10));
    await ContinueWatchingStore.remove(ContinueWatchingStore.keyFor(video));
    expect(await ContinueWatchingStore.load(), isEmpty);
  });

  test('persists WebDAV identity but never Authorization headers', () {
    const securedVideo = VideoItem(
      id: 'webdav_server/file.mkv',
      title: 'file.mkv',
      uri: 'https://example.test/file.mkv',
      resumeKey: 'webdav_server/file.mkv',
      duration: Duration.zero,
      webdavServerId: 'server',
      allowSelfSigned: true,
      httpHeaders: {'Authorization': 'Basic secret'},
    );
    final json = securedVideo.toJson();
    expect(json['webdavServerId'], 'server');
    expect(json['allowSelfSigned'], isTrue);
    expect(json.containsKey('httpHeaders'), isFalse);

    final restored = VideoItem.fromJson(json);
    expect(restored.webdavServerId, 'server');
    expect(restored.httpHeaders, isEmpty);
  });

  test('does not persist a transient STRM target URL', () {
    const strmVideo = VideoItem(
      id: 'tree:library/Movie.strm',
      title: 'Movie',
      uri: 'https://cdn.example/movie.mkv?token=secret',
      resumeKey: 'tree:library/Movie.strm',
      duration: Duration.zero,
      uriIsTransient: true,
    );
    final json = strmVideo.toJson();
    expect(json['uri'], isNull);
    expect(json.toString(), isNot(contains('secret')));
    expect(json['resumeKey'], 'tree:library/Movie.strm');
  });
}

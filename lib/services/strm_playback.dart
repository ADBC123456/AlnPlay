import '../library/models/library_models.dart';
import '../library/source/library_source_adapters.dart';
import '../library/source/strm_file.dart';
import '../models/video_item.dart';
import 'file_browser.dart';
import 'webdav_client.dart';

/// Re-reads a transient STRM pointer immediately before a real play action.
/// Stable identity and metadata stay attached; only the target URI is renewed.
Future<VideoItem> refreshStrmPlayback(VideoItem video) async {
  if (!video.uriIsTransient) return video;

  final localPath = video.path;
  if (localPath != null &&
      (isStrmFileName(video.title) || isStrmFileName(localPath))) {
    await FileBrowserService.instance.resolvePath(localPath);
    final entry = FileEntry(
      name: isStrmFileName(video.title)
          ? video.title
          : localPath.split(RegExp(r'[/\\]')).last,
      path: localPath,
      isDirectory: false,
      size: video.sizeBytes ?? 0,
      resumeKey: video.resumeKey ?? localPath,
    );
    return (await entry.resolvePlayable(
      id: video.id,
    )).withMetadataContext(video.metadataContext);
  }

  final key = video.resumeKey;
  if (key != null && key.startsWith('webdav_')) {
    final encoded = key.substring('webdav_'.length);
    final servers = await WebDavClient.instance.listServers();
    final matches =
        servers
            .where(
              (server) =>
                  encoded.startsWith(server.id) &&
                  encoded.substring(server.id.length).startsWith('/'),
            )
            .toList()
          ..sort((a, b) => b.id.length.compareTo(a.id.length));
    if (matches.isEmpty) {
      throw StateError('The WebDAV server for this STRM file is unavailable');
    }
    final server = matches.first;
    final path = encoded.substring(server.id.length);
    final name = path.split('/').last;
    if (!isStrmFileName(name)) {
      throw const StrmFormatException('The saved STRM source is invalid');
    }
    final file = MediaFile(
      id: video.id,
      rootIds: const {},
      sourceRef: MediaSourceRef(
        sourceId: 'webdav:${server.id}',
        sourceType: 'webdav',
        path: path,
        serverId: server.id,
      ),
      originalFileName: name,
      sizeBytes: video.sizeBytes,
      legacyResumeKey: key,
      isStrm: true,
    );
    return (await WebDavLibrarySourceAdapter(
      server,
    ).resolvePlayable(file)).withMetadataContext(video.metadataContext);
  }

  throw const StrmFormatException('The saved STRM source cannot be refreshed');
}

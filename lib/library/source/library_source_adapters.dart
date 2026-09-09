import 'dart:convert';

import '../../models/video_item.dart';
import '../../services/file_browser.dart';
import '../../services/ftp_client.dart';
import '../../services/jellyfin_client.dart';
import '../../services/library_folders.dart';
import '../../services/smb_client.dart';
import '../../services/upnp_client.dart';
import '../../services/webdav_client.dart';
import '../../utils/file_info_extractor.dart';
import '../models/library_models.dart';
import 'strm_file.dart';

class LibraryAdapterBundle {
  const LibraryAdapterBundle({required this.roots, required this.adapters});

  final List<LibraryRoot> roots;
  final List<LibrarySourceAdapter> adapters;

  static Future<LibraryAdapterBundle> fromFolders(
    List<LibraryFolder> folders,
  ) async {
    final roots = <LibraryRoot>[];
    final adapters = <String, LibrarySourceAdapter>{};
    var webdavServers = <String, WebDavServer>{};
    if (folders.any((folder) => folder.source == LibraryFolderSource.webdav)) {
      try {
        webdavServers = {
          for (final server in await WebDavClient.instance.listServers())
            server.id: server,
        };
      } catch (_) {}
    }
    var ftpServers = <String, FtpServer>{};
    if (folders.any((folder) => folder.source == LibraryFolderSource.ftp)) {
      try {
        ftpServers = {
          for (final server in await FtpClient.instance.listServers())
            server.id: server,
        };
      } catch (_) {}
    }
    for (final folder in folders) {
      final serverId = folder.networkServerId;
      switch (folder.source) {
        case LibraryFolderSource.files:
          const sourceId = 'files:device';
          adapters[sourceId] ??= LocalLibrarySourceAdapter();
          roots.add(_root(folder, sourceId, path: folder.path));
        case LibraryFolderSource.webdav:
          if (serverId == null || webdavServers[serverId] == null) continue;
          final sourceId = 'webdav:$serverId';
          adapters[sourceId] ??= WebDavLibrarySourceAdapter(
            webdavServers[serverId]!,
          );
          roots.add(
            _root(folder, sourceId, path: folder.networkPath ?? folder.path),
          );
        case LibraryFolderSource.ftp:
          if (serverId == null || ftpServers[serverId] == null) continue;
          final sourceId = 'ftp:$serverId';
          adapters[sourceId] ??= FtpLibrarySourceAdapter(ftpServers[serverId]!);
          roots.add(
            _root(folder, sourceId, path: folder.networkPath ?? folder.path),
          );
        case LibraryFolderSource.smb:
          if (serverId == null || folder.networkShare == null) continue;
          final sourceId = 'smb:$serverId';
          adapters[sourceId] ??= SmbLibrarySourceAdapter(serverId);
          roots.add(
            _root(
              folder,
              sourceId,
              path: folder.networkPath ?? '',
              share: folder.networkShare,
            ),
          );
        case LibraryFolderSource.upnp:
          if (serverId == null) continue;
          final sourceId = 'upnp:$serverId';
          adapters[sourceId] ??= UpnpLibrarySourceAdapter(serverId);
          roots.add(_root(folder, sourceId, path: folder.networkPath ?? '0'));
        case LibraryFolderSource.jellyfin:
          final url = folder.jellyfinServerUrl;
          if (url == null) continue;
          final client = JellyfinClient();
          JellyfinServer? server;
          try {
            server = await client.serverForUrl(url);
          } catch (_) {
            continue;
          }
          if (server == null || !server.isAuthenticated) continue;
          final sourceId = 'jellyfin:${server.urlHost}';
          adapters[sourceId] ??= JellyfinLibrarySourceAdapter(server, client);
          roots.add(_root(folder, sourceId, path: folder.jellyfinItemId ?? ''));
      }
    }
    return LibraryAdapterBundle(
      roots: roots,
      adapters: adapters.values.toList(growable: false),
    );
  }

  static LibraryRoot _root(
    LibraryFolder folder,
    String sourceId, {
    required String path,
    String? share,
  }) => LibraryRoot(
    id: folder.id,
    sourceId: sourceId,
    displayName: folder.name,
    maxScanDepth: folder.maxScanDepth.clamp(
      LibraryRoot.minimumMaxScanDepth,
      LibraryRoot.maximumMaxScanDepth,
    ),
    directory: SourceDirectory(
      sourceId: sourceId,
      sourceType: folder.source.name,
      identity: share == null ? path : '$share/$path',
      path: path,
      contextName: folder.name,
      serverId: folder.networkServerId,
      share: share,
    ),
  );
}

class LocalLibrarySourceAdapter
    implements LibrarySourceAdapter, SmallTextLibrarySourceAdapter {
  @override
  String get sourceId => 'files:device';

  @override
  Future<ListingPage> list(SourceDirectory directory, {String? cursor}) async {
    final entries = await FileBrowserService.instance.listDirectory(
      directory.path,
    );
    return ListingPage(
      entries: [
        for (final entry in entries)
          SourceEntry(
            name: entry.name,
            stableId: entry.resumeKey ?? entry.path,
            isDirectory: entry.isDirectory,
            directory: entry.isDirectory
                ? SourceDirectory(
                    sourceId: sourceId,
                    sourceType: 'files',
                    identity: entry.path,
                    path: entry.path,
                    contextName: entry.name,
                  )
                : null,
            sourceRef: entry.isDirectory
                ? null
                : MediaSourceRef(
                    sourceId: sourceId,
                    sourceType: 'files',
                    path: entry.path,
                  ),
            sizeBytes: entry.size,
            legacyResumeKey: entry.resumeKey ?? entry.path,
            isStrm: isStrmFileName(entry.name),
          ),
      ],
    );
  }

  @override
  Future<VideoItem> resolvePlayable(MediaFile file) async {
    await FileBrowserService.instance.resolvePath(file.sourceRef.path);
    final info = extractFileInfo(file.originalFileName);
    final path = file.sourceRef.path;
    if (file.isStrm) {
      final text = await readSmallText(file);
      final target = parseExternalStrm(text ?? '');
      return VideoItem(
        id: file.id,
        title: file.originalFileName.replaceFirst(
          RegExp(r'\.strm$', caseSensitive: false),
          '',
        ),
        uri: target.toString(),
        path: path,
        resumeKey: file.legacyResumeKey,
        duration: Duration.zero,
        uriIsTransient: true,
      );
    }
    return VideoItem(
      id: file.id,
      title: file.originalFileName,
      path: path.startsWith('content://') ? null : path,
      uri: path.startsWith('content://') ? path : null,
      resumeKey: file.legacyResumeKey,
      duration: Duration.zero,
      sizeBytes: file.sizeBytes,
      videoCodec: info.videoCodec,
      audioCodec: info.audioCodec,
      audioChannels: info.audioChannels,
      resolution: info.resolution,
      hdrHint: info.hdrHint,
    );
  }

  @override
  Future<String?> readSmallText(MediaFile file, {int maxBytes = 65536}) =>
      FileBrowserService.instance.readSmallText(
        file.sourceRef.path,
        maxBytes: maxBytes,
        resumeKey: file.legacyResumeKey,
      );
}

class WebDavLibrarySourceAdapter
    implements LibrarySourceAdapter, SmallTextLibrarySourceAdapter {
  WebDavLibrarySourceAdapter(this.server);

  final WebDavServer server;

  @override
  String get sourceId => 'webdav:${server.id}';

  @override
  Future<ListingPage> list(SourceDirectory directory, {String? cursor}) async {
    final entries = await WebDavClient.instance.listDirectory(
      server.id,
      directory.path,
    );
    return ListingPage(
      entries: [
        for (final entry in entries)
          SourceEntry(
            name: entry.name,
            stableId: 'webdav_${server.id}${entry.path}',
            isDirectory: entry.isDirectory,
            directory: entry.isDirectory
                ? _directory(
                    sourceId,
                    'webdav',
                    entry.path,
                    entry.name,
                    server.id,
                  )
                : null,
            sourceRef: entry.isDirectory
                ? null
                : MediaSourceRef(
                    sourceId: sourceId,
                    sourceType: 'webdav',
                    path: entry.path,
                    serverId: server.id,
                  ),
            sizeBytes: entry.size,
            legacyResumeKey: 'webdav_${server.id}${entry.path}',
            isStrm: isStrmFileName(entry.name),
          ),
      ],
    );
  }

  @override
  Future<String?> readSmallText(MediaFile file, {int maxBytes = 65536}) async {
    if (maxBytes <= 0 || maxBytes > 65536) {
      throw ArgumentError.value(
        maxBytes,
        'maxBytes',
        'must be between 1 and 65536',
      );
    }
    if (!isStrmFileName(file.originalFileName) ||
        file.sourceRef.serverId != server.id) {
      return null;
    }
    final base = server.url.replaceAll(RegExp(r'/+$'), '');
    final bytes = await WebDavClient.instance.fetchUrl(
      serverId: server.id,
      url: '$base${_encodePath(file.sourceRef.path)}',
      maxBytes: maxBytes,
    );
    return bytes == null ? null : utf8.decode(bytes);
  }

  @override
  Future<VideoItem> resolvePlayable(MediaFile file) async {
    if (isStrmFileName(file.originalFileName)) {
      final target = parseExternalStrm(await readSmallText(file) ?? '');
      return VideoItem(
        id: file.id,
        title: file.originalFileName,
        uri: target.toString(),
        uriIsTransient: true,
        resumeKey: file.legacyResumeKey,
        duration: Duration.zero,
        sizeBytes: file.sizeBytes,
      );
    }
    String authorization = '';
    try {
      authorization = await WebDavClient.instance.authorizationHeader(
        server.id,
      );
    } catch (_) {}
    final base = server.url.replaceAll(RegExp(r'/+$'), '');
    final info = extractFileInfo(file.originalFileName);
    return VideoItem(
      id: file.id,
      title: file.originalFileName,
      uri: '$base${_encodePath(file.sourceRef.path)}',
      resumeKey: file.legacyResumeKey,
      duration: Duration.zero,
      sizeBytes: file.sizeBytes,
      httpHeaders: authorization.isEmpty
          ? const {}
          : {'Authorization': authorization},
      allowSelfSigned: server.allowSelfSigned,
      webdavServerId: server.id,
      videoCodec: info.videoCodec,
      audioCodec: info.audioCodec,
      audioChannels: info.audioChannels,
      resolution: info.resolution,
      hdrHint: info.hdrHint,
    );
  }
}

class FtpLibrarySourceAdapter implements LibrarySourceAdapter {
  FtpLibrarySourceAdapter(this.server);

  final FtpServer server;

  @override
  String get sourceId => 'ftp:${server.id}';

  @override
  Future<ListingPage> list(SourceDirectory directory, {String? cursor}) async {
    final entries = await FtpClient.instance.listDirectory(
      server.id,
      directory.path,
    );
    return ListingPage(
      entries: [
        for (final entry in entries)
          SourceEntry(
            name: entry.name,
            stableId: 'ftp_${server.id}${entry.path}',
            isDirectory: entry.isDirectory,
            directory: entry.isDirectory
                ? _directory(sourceId, 'ftp', entry.path, entry.name, server.id)
                : null,
            sourceRef: entry.isDirectory
                ? null
                : MediaSourceRef(
                    sourceId: sourceId,
                    sourceType: 'ftp',
                    path: entry.path,
                    serverId: server.id,
                  ),
            sizeBytes: entry.size,
            legacyResumeKey: 'ftp_${server.id}${entry.path}',
          ),
      ],
    );
  }

  @override
  Future<VideoItem> resolvePlayable(MediaFile file) async {
    final encodedPath = file.sourceRef.path
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    final info = extractFileInfo(file.originalFileName);
    return VideoItem(
      id: file.id,
      title: file.originalFileName,
      uri: '${server.isSftp ? 'sftp' : 'ftp'}://${server.id}$encodedPath',
      resumeKey: file.legacyResumeKey,
      duration: Duration.zero,
      sizeBytes: file.sizeBytes,
      ftpServerId: server.id,
      videoCodec: info.videoCodec,
      audioCodec: info.audioCodec,
      audioChannels: info.audioChannels,
      resolution: info.resolution,
      hdrHint: info.hdrHint,
    );
  }
}

class SmbLibrarySourceAdapter implements LibrarySourceAdapter {
  SmbLibrarySourceAdapter(this.serverId);

  final String serverId;

  @override
  String get sourceId => 'smb:$serverId';

  @override
  Future<ListingPage> list(SourceDirectory directory, {String? cursor}) async {
    final share = directory.share ?? '';
    final entries = await SmbClient.instance.listDirectory(
      serverId,
      share,
      directory.path,
    );
    return ListingPage(
      entries: [
        for (final entry in entries)
          SourceEntry(
            name: entry.name,
            stableId: 'smb:$serverId/$share/${entry.path}',
            isDirectory: entry.isDirectory,
            directory: entry.isDirectory
                ? SourceDirectory(
                    sourceId: sourceId,
                    sourceType: 'smb',
                    identity: '$share/${entry.path}',
                    path: entry.path,
                    contextName: entry.name,
                    serverId: serverId,
                    share: share,
                  )
                : null,
            sourceRef: entry.isDirectory
                ? null
                : MediaSourceRef(
                    sourceId: sourceId,
                    sourceType: 'smb',
                    path: entry.path,
                    serverId: serverId,
                    share: share,
                  ),
            sizeBytes: entry.size,
            modifiedAt: entry.modified <= 0
                ? null
                : DateTime.fromMillisecondsSinceEpoch(entry.modified),
            legacyResumeKey: 'smb:$serverId/$share/${entry.path}',
          ),
      ],
    );
  }

  @override
  Future<VideoItem> resolvePlayable(MediaFile file) async {
    final share = file.sourceRef.share ?? '';
    final uri = await SmbClient.instance.openShare(
      serverId,
      share,
      file.sourceRef.path,
    );
    final info = extractFileInfo(file.originalFileName);
    return VideoItem(
      id: file.id,
      title: file.originalFileName,
      uri: uri,
      resumeKey: file.legacyResumeKey,
      duration: Duration.zero,
      sizeBytes: file.sizeBytes,
      videoCodec: info.videoCodec,
      audioCodec: info.audioCodec,
      audioChannels: info.audioChannels,
      resolution: info.resolution,
      hdrHint: info.hdrHint,
    );
  }
}

class UpnpLibrarySourceAdapter implements LibrarySourceAdapter {
  UpnpLibrarySourceAdapter(this.serverId);

  final String serverId;

  @override
  String get sourceId => 'upnp:$serverId';

  @override
  Future<ListingPage> list(SourceDirectory directory, {String? cursor}) async {
    final entries = await UpnpClient.instance.browse(serverId, directory.path);
    return ListingPage(
      entries: [
        for (final entry in entries)
          SourceEntry(
            name: entry.name,
            stableId: 'upnp:$serverId/${entry.id}',
            isDirectory: entry.isDirectory,
            directory: entry.isDirectory
                ? _directory(sourceId, 'upnp', entry.id, entry.name, serverId)
                : null,
            sourceRef: entry.isDirectory || !entry.isVideo
                ? null
                : MediaSourceRef(
                    sourceId: sourceId,
                    sourceType: 'upnp',
                    path: entry.url!,
                    serverId: serverId,
                    itemId: entry.id,
                  ),
            sizeBytes: entry.size,
            legacyResumeKey: 'upnp:$serverId/${entry.id}',
          ),
      ],
    );
  }

  @override
  Future<VideoItem> resolvePlayable(MediaFile file) async {
    final upgraded = await JellyfinClient().upgradeDlnaUrl(
      url: file.sourceRef.path,
      title: file.originalFileName,
      sizeBytes: file.sizeBytes,
    );
    if (upgraded != null) return upgraded;
    final info = extractFileInfo(file.originalFileName);
    return VideoItem(
      id: file.id,
      title: file.originalFileName,
      uri: file.sourceRef.path,
      resumeKey: file.legacyResumeKey,
      duration: Duration.zero,
      sizeBytes: file.sizeBytes,
      videoCodec: info.videoCodec,
      audioCodec: info.audioCodec,
      audioChannels: info.audioChannels,
      resolution: info.resolution,
      hdrHint: info.hdrHint,
    );
  }
}

class JellyfinLibrarySourceAdapter implements LibrarySourceAdapter {
  JellyfinLibrarySourceAdapter(this.server, this.client);

  final JellyfinServer server;
  final JellyfinClient client;

  @override
  String get sourceId => 'jellyfin:${server.urlHost}';

  @override
  Future<ListingPage> list(SourceDirectory directory, {String? cursor}) async {
    final entries = await client.getItems(server, directory.path);
    return ListingPage(
      entries: [
        for (final entry in entries)
          SourceEntry(
            name: entry.name,
            stableId: client.resumeKey(server, entry),
            isDirectory: entry.isFolder,
            directory: entry.isFolder
                ? _directory(
                    sourceId,
                    'jellyfin',
                    entry.id,
                    entry.name,
                    server.urlHost,
                  )
                : null,
            sourceRef: entry.isFolder || !entry.isPlayable
                ? null
                : MediaSourceRef(
                    sourceId: sourceId,
                    sourceType: 'jellyfin',
                    path: entry.id,
                    serverId: server.url,
                    itemId: entry.id,
                  ),
            sizeBytes: entry.sizeBytes,
            seasonNumber: entry.parentIndexNumber,
            episodeNumber: entry.indexNumber,
            legacyResumeKey: client.resumeKey(server, entry),
          ),
      ],
    );
  }

  @override
  Future<VideoItem> resolvePlayable(MediaFile file) async {
    final item = await client.getItem(server, file.sourceRef.itemId ?? '');
    if (item == null) {
      throw StateError('Jellyfin item is no longer available');
    }
    return client.videoItem(server, item);
  }
}

SourceDirectory _directory(
  String sourceId,
  String sourceType,
  String path,
  String name,
  String serverId,
) => SourceDirectory(
  sourceId: sourceId,
  sourceType: sourceType,
  identity: path,
  path: path,
  contextName: name,
  serverId: serverId,
);

// Source adapters retain the decoded filesystem path returned by the native
// browser. DecodeComponent here rejects Chinese characters and also changes
// literal percent sequences in filenames. Encode each raw segment exactly once.
String _encodePath(String path) =>
    path.split('/').map(Uri.encodeComponent).join('/');

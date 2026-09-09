import 'package:flutter/services.dart';

import '../library/source/strm_file.dart';
import '../models/video_item.dart';
import '../utils/file_info_extractor.dart';

/// A directory/file entry returned by the native file browser.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    this.bookmarkId,
    this.resumeKey,
    this.isFilesHome = false,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;

  /// Non-null for folders picked via the system folder picker (bookmarked).
  final String? bookmarkId;

  /// Stable identity for the resume feature, present for files that live
  /// inside a bookmarked folder (iOS). Falls back to [path]/[uri] when null.
  final String? resumeKey;

  /// True for the virtual "Files" root (iOS): tapping it opens the system
  /// document picker — the real Files-app home — instead of listing a path.
  final bool isFilesHome;

  factory FileEntry.fromMap(Map<dynamic, dynamic> map) {
    return FileEntry(
      name: (map['name'] as String?) ?? '',
      path: (map['path'] as String?) ?? '',
      isDirectory: (map['isDirectory'] as bool?) ?? false,
      size: (map['size'] as num?)?.toInt() ?? 0,
      bookmarkId: map['bookmarkId'] as String?,
      resumeKey: map['resumeKey'] as String?,
      isFilesHome: (map['isFilesHome'] as bool?) ?? false,
    );
  }

  /// Stable local-file identity used even when a STRM target URL rotates.
  String get playbackIdentity => resumeKey ?? path;

  VideoItem toVideoItem({String? id}) {
    final isContentUri = path.startsWith('content://');
    final info = extractFileInfo(name);
    return VideoItem(
      id: id ?? 'file_${playbackIdentity.hashCode}',
      title: name,
      path: isContentUri ? null : path,
      uri: isContentUri ? path : null,
      resumeKey: playbackIdentity,
      duration: Duration.zero,
      sizeBytes: size,
      videoCodec: info.videoCodec,
      audioCodec: info.audioCodec,
      audioChannels: info.audioChannels,
      resolution: info.resolution,
      hdrHint: info.hdrHint,
    );
  }

  /// Resolves a local STRM pointer immediately before playback. Only the
  /// bounded pointer text is read; the HTTP(S) target is not requested here.
  Future<VideoItem> resolvePlayable({String? id}) async {
    if (!isStrmFileName(name)) return toVideoItem(id: id);
    final text = await FileBrowserService.instance.readSmallText(
      path,
      resumeKey: playbackIdentity,
    );
    if (text == null) {
      throw const StrmFormatException('This STRM file could not be read');
    }
    final target = parseExternalStrm(text);
    final targetName = target.pathSegments.isEmpty
        ? name
        : Uri.decodeComponent(target.pathSegments.last);
    final info = extractFileInfo(targetName);
    return VideoItem(
      id: id ?? 'file_${playbackIdentity.hashCode}',
      title: name,
      path: path,
      uri: target.toString(),
      resumeKey: playbackIdentity,
      duration: Duration.zero,
      videoCodec: info.videoCodec,
      audioCodec: info.audioCodec,
      audioChannels: info.audioChannels,
      resolution: info.resolution,
      hdrHint: info.hdrHint,
      uriIsTransient: true,
    );
  }
}

/// Wraps the native `dreamplayer/files` channel (see `FileBrowser.kt`).
class FileBrowserService {
  FileBrowserService._();

  static final FileBrowserService instance = FileBrowserService._();

  static const MethodChannel _channel = MethodChannel('dreamplayer/files');

  /// True when the app can freely read the whole filesystem
  /// (always true below Android 11 and on iOS).
  Future<bool> hasAllFilesAccess() async {
    final result = await _channel.invokeMethod<bool>('hasAllFilesAccess');
    return result ?? false;
  }

  /// Launches the system "All files access" settings page for this app.
  Future<void> openAllFilesAccessSettings() async {
    await _channel.invokeMethod<void>('openAllFilesAccessSettings');
  }

  /// Storage roots (internal storage, SD card) shown at the top level.
  Future<List<FileEntry>> storageRoots() async {
    final result = await _channel.invokeListMethod<dynamic>('getStorageRoots');
    if (result == null) return const [];
    return result
        .map((e) => FileEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Directories (first) and video files inside [path].
  Future<List<FileEntry>> listDirectory(String path) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectory', {
      'path': path,
    });
    if (result == null) return const [];
    return result
        .where((e) => (e as Map<dynamic, dynamic>)['error'] == null)
        .map((e) => FileEntry.fromMap(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Reads a bounded UTF-8 text file without loading an unbounded object.
  Future<String?> readSmallText(
    String path, {
    int maxBytes = 65536,
    String? resumeKey,
  }) async {
    return _channel.invokeMethod<String>('readSmallText', {
      'path': path,
      'maxBytes': maxBytes.clamp(1, 65536),
      'resumeKey': ?resumeKey,
    });
  }

  /// Presents the system folder picker (iOS document picker / Android
  /// ACTION_OPEN_DOCUMENT_TREE). Returns the picked folder, bookmarked for
  /// future sessions, or null if the user cancelled.
  Future<FileEntry?> pickFolder() async {
    final result = await _channel.invokeMapMethod<dynamic, dynamic>(
      'pickFolder',
    );
    if (result == null) return null;
    return FileEntry.fromMap(result);
  }

  /// Same folder picker, but the picked folder is stored as a LIBRARY bookmark
  /// only — it never appears as a file-browser root. Used by "Add folder to
  /// library".
  Future<FileEntry?> pickLibraryFolder() async {
    final result = await _channel.invokeMapMethod<dynamic, dynamic>(
      'pickLibraryFolder',
    );
    if (result == null) return null;
    return FileEntry.fromMap(result);
  }

  /// iOS only: presents the system document picker — the Files-app home
  /// (iCloud Drive, On My iPad, Downloads, providers). Returns the picked
  /// video, imported (bookmarked) for future sessions, or null if cancelled.
  Future<FileEntry?> openFilesHome() async {
    final result = await _channel.invokeMapMethod<dynamic, dynamic>(
      'openFilesHome',
    );
    if (result == null) return null;
    return FileEntry.fromMap(result);
  }

  /// Re-grants native access to an imported video's file (iOS security-scoped
  /// bookmarks). No-op on Android.
  Future<bool> resolveImportedPath(String path) async {
    final result = await _channel.invokeMethod<bool>('resolveImportedPath', {
      'path': path,
    });
    return result ?? true;
  }

  /// Re-grants native access to [path] whether it's an imported video or lives
  /// inside a bookmarked folder (iOS re-resolves the folder's security-scoped
  /// bookmark and starts its scope). No-op on Android.
  Future<bool> resolvePath(String path) async {
    final result = await _channel.invokeMethod<bool>('resolvePath', {
      'path': path,
    });
    return result ?? true;
  }

  /// Forgets a bookmarked folder.
  Future<void> removeBookmark(String bookmarkId) async {
    await _channel.invokeMethod<void>('removeBookmark', {
      'bookmarkId': bookmarkId,
    });
  }

  /// Forgets a library-folder bookmark (when a folder is removed from the
  /// library, so its native grant doesn't linger).
  Future<void> removeLibraryBookmark(String bookmarkId) async {
    await _channel.invokeMethod<void>('removeLibraryBookmark', {
      'bookmarkId': bookmarkId,
    });
  }

  /// Presents the system file picker filtered to subtitle files (SRT/ASS/VTT).
  /// Returns the picked file's URI string (content:// on Android, file:// on
  /// iOS) or null if cancelled.
  Future<String?> pickSubtitle() async {
    final result = await _channel.invokeMethod<String>('pickSubtitle');
    return result;
  }

  /// Embedded cover-art bytes for a local video (metadata-only read — safe for
  /// DV/HDR). Returns null when the file has no attached artwork or the source
  /// is remote (http(s) is skipped natively).
  Future<Uint8List?> getThumbnail({String? path, String? uri}) async {
    try {
      return await _channel.invokeMethod<Uint8List>('getThumbnail', {
        'path': path,
        'uri': uri,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Engine not attached (tests / teardown).
      return null;
    }
  }
}

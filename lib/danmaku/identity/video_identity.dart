/// Video identity for the danmaku feature.
///
/// Produces a **stable per-video key** (survives app restarts) and an
/// optional `fileHash` (MD5 of the file's first 16 MiB) for the `danmu_api`
/// `/api/v2/match` request.
///
/// Identity rules (PRD "缓存与刮削结果"):
/// - The stable key must not rotate when the source hands out rotating URLs
///   (Jellyfin tokens, CX proxy ports, per-session SMB tokens). We key on the
///   same identifiers the rest of the app already trusts: `resumeKey`
///   (source-qualified, stable) > file path > URL-derived identity.
/// - The MD5 is **content**, never part of the key: remote files can't be
///   hashed, and local hashing is best-effort (the app may lose All-Files
///   Access between sessions).
/// - TMDB ids never enter the key: the danmaku anime/episode ids are a
///   different namespace and must not be conflated with TMDB.
library;

import 'dart:io';
import 'dart:isolate';

import 'dart:typed_data';

import '../../models/video_item.dart';
import 'md5.dart';

/// Bytes hashed from the head of the file for `fileHash` (16 MiB).
const int danmakuHashBytes = 16 * 1024 * 1024;

/// Prefix distinguishing danmaku identity keys from other key namespaces
/// (`folder:`, resume keys…). Kept out of the resume-key space so a renamed
/// source key shape can never collide.
const String danmakuIdentityPrefix = 'danmaku:';

/// Converts every producer's resume/file key to the one canonical namespace.
String normalizeDanmakuIdentityKey(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith(danmakuIdentityPrefix)) return trimmed;
  return '$danmakuIdentityPrefix$trimmed';
}

/// Pre-namespace key used by older binding and cache records.
String legacyDanmakuIdentityKey(String value) {
  final normalized = normalizeDanmakuIdentityKey(value);
  return normalized.substring(danmakuIdentityPrefix.length);
}

/// Reads the first [bytes] of [path] and returns their MD5 hex. Null when
/// the file can't be read (missing, permission, IO error) — callers fall
/// back to metadata identity. Streams in 1 MiB chunks.
String? hashLocalFileHead(String path, {int bytes = danmakuHashBytes}) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    final len = f.lengthSync();
    if (len <= 0) return null;
    final raf = f.openSync();
    try {
      final h = Md5();
      const chunkSize = 1 << 20;
      final limit = bytes < len ? bytes : len;
      final buffer = Uint8List(chunkSize);
      var read = 0;
      while (read < limit) {
        final take = limit - read < chunkSize ? limit - read : chunkSize;
        final n = raf.readIntoSync(buffer, 0, take);
        if (n <= 0) break;
        h.addBytes(buffer, 0, n);
        read += n;
      }
      if (read == 0) return null;
      return h.digestHex();
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// Stable identity for a video across app restarts.
class VideoIdentity {
  const VideoIdentity({
    required this.stableKey,
    required this.fileName,
    this.fileSize,
    this.fileHash,
  });

  /// Stable, restart-proof identity. Namespaced with `danmaku:`.
  final String stableKey;

  /// Display/lookup file name (no directory). Never empty for usable items.
  final String fileName;

  /// File size in bytes when known (listing metadata or local stat).
  final int? fileSize;

  /// MD5 of the file's first 16 MiB when the content is locally readable.
  /// Null for remote/unreadable sources — matching then uses
  /// fileName + fileSize.
  final String? fileHash;

  /// matchMode per the danmu_api protocol.
  String get matchMode => fileHash != null ? 'hashAndFileName' : 'fileName';

  @override
  String toString() =>
      'VideoIdentity($stableKey, $fileName, $fileSize, hash: $fileHash)';
}

/// Derives the stable identity for [video].
///
/// The key is built from identifiers that persist across sessions:
/// 1. `resumeKey` — the source-qualified stable id the app already trusts
///    (`jellyfin:<host>/<item>`, `webdav_<serverId><path>`,
///    `smb:<serverId>/<share>/<path>`, `ftp_<serverId><path>`, plain path…).
/// 2. [VideoItem.path] for plain local files.
/// 3. [VideoItem.uri] **with query/fragment stripped** (Jellyfin stream URLs
///    rotate their `api_key`) — used only when no resumeKey/path exists.
///
/// A hash is attempted ONLY when the content is locally readable:
/// - plain local paths (`/…`) and `file://` URIs;
/// - `content://` SAF URIs are NOT hashed (per-read binder overhead; the
///   identity falls back to path/size — still stable);
/// - http(s)/smb/ftp/sftp URLs are never hashed here.
VideoIdentity identityFor(
  VideoItem video, {
  String? Function(String path)? localHasher = hashLocalFileHead,
}) {
  final fileName = _fileNameOf(video);
  final fileSize = _fileSizeOf(video);

  String? hash;
  final path = _localPathOf(video);
  if (path != null && localHasher != null) {
    hash = localHasher(path);
  }

  return VideoIdentity(
    stableKey: normalizeDanmakuIdentityKey(_stableKeyBody(video)),
    fileName: fileName,
    fileSize: fileSize,
    fileHash: hash,
  );
}

/// Async variant for UI call sites. Reading and hashing the first 16 MiB can
/// take long enough to miss frames on network-backed storage, so that work is
/// isolated while stable-key derivation remains immediate.
Future<VideoIdentity> identityForAsync(VideoItem video) async {
  final identity = identityFor(video, localHasher: null);
  final path = _localPathOf(video);
  if (path == null) return identity;
  try {
    if (!File(path).existsSync()) return identity;
  } on FileSystemException {
    return identity;
  }
  final hash = await Isolate.run(() => hashLocalFileHead(path));
  return VideoIdentity(
    stableKey: identity.stableKey,
    fileName: identity.fileName,
    fileSize: identity.fileSize,
    fileHash: hash,
  );
}

/// Pure stable-key body (without the `danmaku:` prefix) — exposed for tests.
String stableKeyBodyOf(VideoItem video) => _stableKeyBody(video);

String _stableKeyBody(VideoItem video) {
  final resumeKey = video.resumeKey;
  if (resumeKey != null && resumeKey.isNotEmpty) return resumeKey;

  final path = video.path;
  if (path != null && path.isNotEmpty) return path;

  final uri = video.uri;
  if (uri != null && uri.isNotEmpty) {
    // Strip query/fragment: Jellyfin stream URLs embed the rotating
    // `api_key`; the path is the stable part.
    final parsed = Uri.tryParse(uri);
    if (parsed != null && parsed.scheme.isNotEmpty) {
      final host = parsed.hasAuthority ? parsed.host : '';
      final port = parsed.hasAuthority && parsed.port != 0
          ? ':${parsed.port}'
          : '';
      return '$host$port${parsed.path}';
    }
    return uri;
  }

  // Nothing stable — last resort. Should not happen for playable items.
  return 'id:${video.id}';
}

/// File name (no directories) from title/path/uri — the name the danmaku
/// match API sees. Percent-decodes URL names (`Show%20S01E01.mkv` →
/// `Show S01E01.mkv`).
String _fileNameOf(VideoItem video) {
  for (final raw in <String>[video.path ?? '', video.uri ?? '', video.title]) {
    if (raw.isEmpty) continue;
    // Strip query/fragment for URL-ish strings.
    var s = raw.split('?').first.split('#').first;
    if (s.isEmpty) continue;
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    final slash = s.lastIndexOf('/');
    final name = slash >= 0 ? s.substring(slash + 1) : s;
    if (name.isEmpty) continue;
    final decoded = _tryDecode(name);
    if (decoded.isNotEmpty && decoded != '/') return decoded;
  }
  return video.title;
}

int? _fileSizeOf(VideoItem video) {
  if (video.sizeBytes != null && video.sizeBytes! > 0) return video.sizeBytes;
  final path = _localPathOf(video);
  if (path == null) return null;
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    final len = f.lengthSync();
    return len > 0 ? len : null;
  } catch (_) {
    return null;
  }
}

/// The local filesystem path when the content is directly readable, else
/// null. `content://` URIs are deliberately excluded (see [identityFor]).
String? _localPathOf(VideoItem video) {
  final path = video.path;
  if (path != null && path.isNotEmpty && !path.contains('://')) return path;
  final uri = video.uri;
  if (uri != null && uri.isNotEmpty && uri.startsWith('file://')) {
    try {
      return Uri.parse(uri).toFilePath();
    } catch (_) {
      return null;
    }
  }
  return null;
}

String _tryDecode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

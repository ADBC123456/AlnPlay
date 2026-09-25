import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent TMDB artwork, separate from disposable playback caches.
/// Files are retained until explicit deletion; image bytes stay out of Dart RAM.
class ImageCacheService {
  ImageCacheService({
    Future<Directory> Function()? directory,
    Future<Uint8List?> Function(Uri)? download,
  }) : _directoryProvider = directory,
       _downloader = download;

  static final _shared = ImageCacheService();
  @visibleForTesting
  static ImageCacheService? instanceForTesting;
  static ImageCacheService get instance => instanceForTesting ?? _shared;
  static const maxImageBytes = 12 * 1024 * 1024;
  static const maxDownloads = 3;
  final Future<Directory> Function()? _directoryProvider;
  final Future<Uint8List?> Function(Uri)? _downloader;
  final Map<String, (int, Future<File?>)> _pending = {};
  final Queue<Completer<void>> _waiters = Queue();
  final Set<String> _prefetch = {};
  Future<Directory>? _directory;
  Future<void> _writes = Future.value();
  Future<void>? _clearing;
  bool _prefetching = false;
  int _active = 0;
  int _revision = 0;

  static Uri? _uri(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'image.tmdb.org' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(
          r'^/t/p/(w\d+|original)/[A-Za-z0-9_-]+\.(jpg|png|webp)$',
          caseSensitive: false,
        ).hasMatch(uri.path)) {
      return null;
    }
    return uri;
  }

  static bool supports(String url) => _uri(url) != null;

  /// Artwork sizes are stored as `w<width>.img`; `original` is the largest.
  static int _widthOf(String path) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    final digits = RegExp(r'\d+').firstMatch(name);
    return digits == null ? 1 << 20 : int.parse(digits.group(0)!);
  }

  Future<Directory> _root() => _directory ??= () async {
    final directory = _directoryProvider != null
        ? await _directoryProvider()
        : Directory(
            '${(await getApplicationSupportDirectory()).path}/tmdb_artwork',
          );
    await directory.create(recursive: true);
    return directory;
  }();

  Future<File> _file(Uri uri) async => File(
    '${(await _root()).path}/${uri.pathSegments.last}/${uri.pathSegments[2]}.img',
  );

  Future<File?> _exact(Uri uri) async {
    final exact = await _file(uri);
    if (await exact.exists() && await exact.length() > 0) return exact;
    return null;
  }

  /// Any cached size of the same artwork, largest first. A poster fetched at
  /// w342 must also work for a w185 tile, and vice versa, when offline.
  Future<File?> _anyCached(Uri uri) async {
    final exact = await _file(uri);
    if (await exact.parent.exists()) {
      final candidates = <File>[];
      await for (final entity in exact.parent.list(followLinks: false)) {
        if (entity is File &&
            entity.path.endsWith('.img') &&
            await entity.length() > 0) {
          candidates.add(entity);
        }
      }
      candidates.sort((a, b) => _widthOf(b.path).compareTo(_widthOf(a.path)));
      return candidates.firstOrNull;
    }
    return null;
  }

  Future<File?> fetch(String url) async {
    final uri = _uri(url);
    if (uri == null) return null;
    await _clearing;
    final revision = _revision;
    final pending = _pending[url];
    if (pending != null && pending.$1 == revision) return pending.$2;
    final operation = _fetch(uri, revision);
    _pending[url] = (revision, operation);
    try {
      return await operation;
    } finally {
      if (identical(_pending[url]?.$2, operation)) _pending.remove(url);
    }
  }

  Future<File?> _fetch(Uri uri, int revision) async {
    try {
      final cached = await _exact(uri);
      if (revision != _revision) return null;
      if (cached != null) return cached;
      await _acquire();
      Uint8List? bytes;
      try {
        if (revision != _revision) return null;
        bytes = await (_downloader ?? _download)(uri);
      } catch (_) {
        // Offline: the largest cached size still beats showing nothing.
        bytes = null;
      } finally {
        _release();
      }
      if (revision != _revision) return null;
      if (bytes == null || bytes.isEmpty || bytes.length > maxImageBytes) {
        return await _anyCached(uri);
      }
      final target = await _file(uri);
      var written = false;
      await _serial(() async {
        if (revision != _revision) return;
        await target.parent.create(recursive: true);
        final temporary = File('${target.path}.tmp');
        try {
          await temporary.writeAsBytes(bytes!, flush: true);
          if (revision != _revision) return;
          await temporary.rename(target.path);
          written = true;
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      });
      return written && revision == _revision ? target : null;
    } catch (_) {
      // Disk/network/plugin failures leave the existing placeholder usable.
      _directory = null;
      return null;
    }
  }

  Future<void> _acquire() async {
    if (_active < maxDownloads) {
      _active++;
    } else {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }

  void _release() {
    if (_waiters.isEmpty) {
      _active--;
    } else {
      _waiters.removeFirst().complete();
    }
  }

  Future<void> _serial(Future<void> Function() work) {
    final operation = _writes.then((_) => work());
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void prefetch(Iterable<String?> urls) {
    for (final url in urls) {
      if (_prefetch.length >= 256) break;
      if (url != null && supports(url)) _prefetch.add(url);
    }
    if (!_prefetching) unawaited(_drainPrefetch());
  }

  Future<void> _drainPrefetch() async {
    _prefetching = true;
    try {
      while (_prefetch.isNotEmpty) {
        final batch = _prefetch.take(maxDownloads).toList();
        _prefetch.removeAll(batch);
        await Future.wait(batch.map(fetch));
      }
    } finally {
      _prefetching = false;
    }
  }

  Future<int> diskSizeBytes() async {
    try {
      var total = 0;
      await for (final entity in (await _root()).list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && entity.path.endsWith('.img')) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<void> clear() {
    final pending = _clearing;
    if (pending != null) return pending;
    _revision++;
    _prefetch.clear();
    final operation = _serial(() async {
      Directory directory;
      try {
        directory = await _root();
      } on MissingPluginException {
        _directory = null;
        return;
      }
      if (await directory.exists()) await directory.delete(recursive: true);
      await directory.create(recursive: true);
    });
    _clearing = operation;
    return operation.whenComplete(() => _clearing = null);
  }

  static Future<Uint8List?> _download(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        // Artwork requests carry no saved server credentials and never redirect.
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 200 ||
            response.contentLength > maxImageBytes ||
            response.headers.contentType?.primaryType != 'image') {
          return null;
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxImageBytes) return null;
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      })().timeout(const Duration(seconds: 20));
    } finally {
      client.close(force: true);
    }
  }
}

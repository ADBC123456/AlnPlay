import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owns only regenerable AlnPlay cache files, never the whole platform cache.
/// Writes and eviction share one queue, including the temporary-file budget.
class CacheQuotaManager extends ChangeNotifier {
  CacheQuotaManager({List<Directory>? roots, int? initialLimitBytes})
    : _testRoots = roots,
      _limitBytes = initialLimitBytes ?? defaultLimitBytes;

  static final _shared = CacheQuotaManager();
  @visibleForTesting
  static CacheQuotaManager? instanceForTesting;
  static CacheQuotaManager get instance => instanceForTesting ?? _shared;
  static const gib = 1024 * 1024 * 1024;
  static const defaultLimitBytes = 5 * gib;
  static const choices = [1, 2, 5, 10, 50, 0];
  static const preferenceKey = 'dreamplayer.cacheLimitBytes';
  static const _channel = MethodChannel('dreamplayer/cache');
  static const _directories = {
    'danmaku',
    'cover_art',
    'sidecar_subs',
    'opensubs',
    'native_subtitles',
  };
  final List<Directory>? _testRoots;
  final Map<String, int> _leases = {};
  final Map<String, DateTime> _access = {};
  List<Directory> _roots = [];
  Future<void>? _initializing;
  Future<void> _tail = Future.value();
  Timer? _maintenance;
  int _limitBytes;
  int _usedBytes = 0;
  int _playbackSessions = 0;
  int _evictionRevision = 0;
  bool _clearPending = false;

  int get limitBytes => _limitBytes; // 0 means unlimited
  int get usedBytes => _usedBytes;
  int get evictionRevision => _evictionRevision;
  bool get overLimit => _limitBytes > 0 && _usedBytes > _limitBytes;
  bool get pendingClear => _clearPending;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (_testRoots != null) {
      _roots = _testRoots;
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(preferenceKey);
      if (saved != null && choices.any((g) => saved == g * gib)) {
        _limitBytes = saved;
      }
      final temporary = await getTemporaryDirectory();
      final cache = await getApplicationCacheDirectory();
      _roots = {
        temporary.absolute.path,
        cache.absolute.path,
      }.map(Directory.new).toList();
      await _syncNativePolicy();
      _maintenance = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(trim().catchError((_) {}));
      });
    } on MissingPluginException {
      // Widget tests and unsupported desktop hosts still show preferences.
    } on PlatformException {
      // A host without the optional cache bridge must not break startup.
    } on FileSystemException {
      // Optional cache directories may temporarily be unavailable.
    }
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  String _path(String value) => File(value).absolute.path.replaceAll('\\', '/');

  bool _managed(String path) {
    final full = _path(path);
    for (final root in _roots) {
      final prefix = '${_path(root.path)}/';
      if (!full.startsWith(prefix)) continue;
      final relative = full.substring(prefix.length);
      // Reject traversal, and never allow a symlink escape during enumeration.
      if (relative.split('/').contains('..')) return false;
      if (_testRoots != null) return true;
      if (_directories.contains(relative.split('/').first)) return true;
      if (!relative.contains('/') &&
          (RegExp(r'^dreamplayer_sub_\d+\.utf8$').hasMatch(relative) ||
              RegExp(r'^picked_sub_\d+\.[a-zA-Z0-9]+$').hasMatch(relative))) {
        return true;
      }
    }
    return false;
  }

  bool _protected(String path) {
    if ((_leases[_path(path)] ?? 0) > 0) return true;
    // Native players can retain subtitle descriptors through seek/reopen.
    // Conservatively lease subtitle cache groups for the player lifetime.
    return _playbackSessions > 0 &&
        (path.contains('/sidecar_subs/') ||
            path.contains('/opensubs/') ||
            path.contains('/native_subtitles/') ||
            path.split('/').last.startsWith('dreamplayer_sub_') ||
            path.split('/').last.startsWith('picked_sub_'));
  }

  Future<List<(File, FileStat)>> _files() async {
    final found = <String, (File, FileStat)>{};
    for (final root in _roots) {
      if (!await root.exists()) continue;
      // Enumerate only explicitly managed subdirectories in production.
      final locations = _testRoots != null
          ? [root]
          : [for (final name in _directories) Directory('${root.path}/$name')];
      for (final directory in locations) {
        if (!await directory.exists()) continue;
        if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          continue;
        }
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File || !_managed(entity.path)) continue;
          final stat = await entity.stat();
          if (stat.type == FileSystemEntityType.file) {
            found[_path(entity.path)] = (entity, stat);
          }
        }
      }
      if (_testRoots == null) {
        await for (final entity in root.list(followLinks: false)) {
          if (entity is File && _managed(entity.path)) {
            final stat = await entity.stat();
            if (stat.type == FileSystemEntityType.file) {
              found[_path(entity.path)] = (entity, stat);
            }
          }
        }
      }
    }
    return found.values.toList();
  }

  Future<int> _trim({
    int incoming = 0,
    String? exclude,
    bool clear = false,
  }) async {
    final files = await _files();
    var total = files.fold<int>(0, (sum, e) => sum + e.$2.size);
    final before = total;
    files.sort(
      (a, b) => (_access[_path(a.$1.path)] ?? a.$2.modified).compareTo(
        _access[_path(b.$1.path)] ?? b.$2.modified,
      ),
    );
    for (final (file, stat) in files) {
      if (!clear && (_limitBytes == 0 || total + incoming <= _limitBytes)) {
        break;
      }
      final path = _path(file.path);
      if (path == exclude || _protected(path)) continue;
      // Our own writes are serialized; recent native temp writes are retained.
      if (path.endsWith('.tmp') &&
          DateTime.now().difference(stat.modified).inMinutes < 10) {
        continue;
      }
      try {
        // Recheck type immediately before deleting; never follow a link.
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        await file.delete();
        total -= stat.size;
        _access.remove(path);
        _evictionRevision++;
      } on FileSystemException {
        /* In use or already removed by the OS. */
      }
    }
    _usedBytes = total;
    notifyListeners();
    return before - total;
  }

  Future<void> setLimit(int bytes) async {
    if (bytes < 0 ||
        (_testRoots == null && !choices.any((g) => bytes == g * gib))) {
      throw ArgumentError.value(bytes, 'bytes');
    }
    await initialize();
    if (_testRoots == null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(preferenceKey, bytes);
    }
    await _serial(() async {
      _limitBytes = bytes;
      await _syncNativePolicy();
      await _trim();
    });
  }

  Future<void> trim() async {
    await initialize();
    await _serial(() async {
      await _trim(clear: _clearPending);
      if (_playbackSessions == 0 && _leases.isEmpty) _clearPending = false;
    });
  }

  Future<int> size() async {
    await initialize();
    return _serial(() async {
      _usedBytes = (await _files()).fold<int>(0, (sum, e) => sum + e.$2.size);
      return _usedBytes;
    });
  }

  Future<int> clear() async {
    await initialize();
    return _serial(() async {
      _clearPending = _playbackSessions > 0 || _leases.isNotEmpty;
      return _trim(clear: true);
    });
  }

  /// Returns false when optional caching would exceed the selected capacity.
  Future<bool> write(File file, List<int> bytes) async {
    await initialize();
    return _serial(() async {
      if (!_managed(file.path)) return false;
      final path = _path(file.path);
      if (_protected(path) && await file.exists()) return false;
      if (_limitBytes > 0 && bytes.length > _limitBytes) return false;
      // Include old file + replacement simultaneously until atomic rename.
      await _trim(incoming: bytes.length, exclude: path);
      if (_limitBytes > 0 && _usedBytes + bytes.length > _limitBytes) {
        return false;
      }
      if (!await _reserveNative(bytes.length)) return false;
      final temporary = File('$path.tmp');
      try {
        await file.parent.create(recursive: true);
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
        _access[path] = DateTime.now();
        _usedBytes = (await _files()).fold<int>(0, (sum, e) => sum + e.$2.size);
        notifyListeners();
        return true;
      } on FileSystemException {
        return false;
      } finally {
        try {
          if (await temporary.exists()) await temporary.delete();
        } finally {
          await _releaseNative(bytes.length);
        }
      }
    });
  }

  Future<void> touch(String path) async {
    await initialize();
    if (!_managed(path)) return;
    final now = DateTime.now();
    final previous = _access[_path(path)];
    if (previous != null && now.difference(previous).inSeconds < 30) return;
    _access[_path(path)] = now;
    try {
      await File(path).setLastModified(now);
    } on FileSystemException {
      /* Evicted. */
    }
  }

  void lease(String path) =>
      _leases.update(_path(path), (n) => n + 1, ifAbsent: () => 1);
  Future<void> release(String path) async {
    final key = _path(path);
    final count = _leases[key] ?? 0;
    if (count <= 1) {
      _leases.remove(key);
    } else {
      _leases[key] = count - 1;
    }
    await trim();
  }

  void beginPlayback() {
    _playbackSessions++;
    unawaited(initialize().then((_) => _syncNativePolicy()));
  }

  Future<void> endPlayback() async {
    if (_playbackSessions > 0) _playbackSessions--;
    await initialize();
    await _syncNativePolicy();
    await trim();
  }

  Future<void> _syncNativePolicy() async {
    if (_testRoots != null) return;
    try {
      await _channel.invokeMethod<void>('policy', {
        'limitBytes': _limitBytes,
        'playbackActive': _playbackSessions > 0,
      });
    } on MissingPluginException {
      /* Unsupported host. */
    } on PlatformException {
      /* Cache policy must not stop playback. */
    }
  }

  Future<bool> _reserveNative(int bytes) async {
    if (_testRoots != null) return true;
    try {
      return await _channel.invokeMethod<bool>('reserveWrite', {
            'bytes': bytes,
          }) ??
          false;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _releaseNative(int bytes) async {
    if (_testRoots != null) return;
    try {
      await _channel.invokeMethod<void>('releaseWrite', {'bytes': bytes});
    } on MissingPluginException {
      /* No native writer on this host. */
    } on PlatformException {
      /* Disposal must remain best-effort. */
    }
  }

  @override
  void dispose() {
    _maintenance?.cancel();
    super.dispose();
  }
}

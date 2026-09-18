import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_item.dart';
import '../services/library_folders.dart';
import '../services/tmdb_client.dart';
import 'metadata/library_metadata_resolver.dart';
import 'models/library_models.dart';
import 'repository/library_repository.dart';
import 'scanner/library_scanner.dart';
import 'source/library_source_adapters.dart';

class UnifiedLibraryService extends ChangeNotifier {
  UnifiedLibraryService._();

  static final UnifiedLibraryService instance = UnifiedLibraryService._();
  static const Duration staleAfter = Duration(minutes: 30);
  static const String _scanTimesKey = 'dreamplayer.libraryScanTimes';

  final JsonLibraryRepository repository = JsonLibraryRepository();
  LibrarySnapshot snapshot = const LibrarySnapshot();
  Map<String, ScanProgress> progressByRoot = const {};
  Map<String, LibrarySourceAdapter> _adapters = const {};
  CoordinatedLibraryScanner? _scanner;
  StreamSubscription<LibrarySnapshot>? _snapshotSubscription;
  StreamSubscription<ScanProgress>? _progressSubscription;
  Future<void>? _initializing;
  Future<void>? _refreshing;
  Future<void>? _clearing;
  int _revision = 0;
  final Map<String, LibraryFolder> _queuedFolders = {};

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    snapshot = await repository.snapshot();
    _snapshotSubscription = repository.watch().listen((value) {
      snapshot = value;
      notifyListeners();
    });
    notifyListeners();
  }

  Future<void> refreshStale(List<LibraryFolder> folders) async {
    if (_clearing != null) return;
    final revision = _revision;
    await initialize();
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_scanTimesKey) ?? const [];
    final times = <String, int>{};
    for (final row in saved) {
      final split = row.lastIndexOf('|');
      if (split <= 0) continue;
      final timestamp = int.tryParse(row.substring(split + 1));
      if (timestamp != null) times[row.substring(0, split)] = timestamp;
    }
    final now = DateTime.now();
    final staleIds = folders
        .where((folder) {
          final ms = times[folder.id];
          return ms == null ||
              now.difference(DateTime.fromMillisecondsSinceEpoch(ms)) >=
                  staleAfter;
        })
        .map((folder) => folder.id)
        .toSet();
    if (staleIds.isEmpty || revision != _revision) return;
    await refresh(
      folders.where((folder) => staleIds.contains(folder.id)).toList(),
    );
  }

  Future<void> refresh(List<LibraryFolder> folders) {
    if (_clearing != null) return Future.value();
    for (final folder in folders) {
      _queuedFolders[folder.id] = folder;
    }
    final running = _refreshing;
    if (running != null) return running;
    final operation = _drainRefresh();
    _refreshing = operation;
    return operation.whenComplete(() {
      if (identical(_refreshing, operation)) _refreshing = null;
    });
  }

  Future<void> _drainRefresh() async {
    while (_queuedFolders.isNotEmpty && _clearing == null) {
      final batch = _queuedFolders.values.toList();
      _queuedFolders.clear();
      await _refresh(batch);
    }
  }

  Future<void> _refresh(List<LibraryFolder> folders) async {
    final revision = _revision;
    await initialize();
    if (folders.isEmpty || revision != _revision || _clearing != null) return;
    final bundle = await LibraryAdapterBundle.fromFolders(folders);
    if (_clearing != null || revision != _revision) return;
    _adapters = {
      ..._adapters,
      for (final adapter in bundle.adapters) adapter.sourceId: adapter,
    };
    await _progressSubscription?.cancel();
    final scanner = CoordinatedLibraryScanner(
      repository: repository,
      adapters: bundle.adapters,
      metadataResolver: TmdbLibraryMetadataResolver(repository: repository),
    );
    _scanner = scanner;
    _progressSubscription = scanner.progress.listen((progress) {
      progressByRoot = {...progressByRoot, progress.rootId: progress};
      notifyListeners();
      if (progress.state == ScanState.complete) {
        unawaited(_recordSuccessfulScan(progress.rootId));
      }
    });
    await scanner.refreshRoots(bundle.roots);
  }

  void cancel(String rootId) => _scanner?.cancel(rootId);

  Future<void> clearLibrary() {
    final pending = _clearing;
    if (pending != null) return pending;
    _revision++;
    _queuedFolders.clear();
    final operation = _clearLibrary();
    _clearing = operation;
    return operation.whenComplete(() => _clearing = null);
  }

  Future<void> _clearLibrary() async {
    await initialize();
    _scanner?.cancelAll();
    await _refreshing;
    final folders = await LibraryFoldersStore.load();
    await LibraryFoldersStore.clearAll();
    await repository.clearAll();
    for (final folder in folders) {
      await TmdService.instance.clear(folder.metadataKey);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_scanTimesKey);
    snapshot = const LibrarySnapshot();
    progressByRoot = const {};
    _adapters = const {};
    notifyListeners();
  }

  Future<VideoItem> resolvePlayable(MediaFile file) async {
    var adapter = _adapters[file.sourceRef.sourceId];
    if (adapter == null) {
      final folders = await LibraryFoldersStore.load();
      final bundle = await LibraryAdapterBundle.fromFolders(folders);
      _adapters = {
        for (final candidate in bundle.adapters) candidate.sourceId: candidate,
      };
      adapter = _adapters[file.sourceRef.sourceId];
    }
    if (adapter == null) {
      throw StateError('Source is no longer configured');
    }
    return adapter.resolvePlayable(file);
  }

  Future<void> _recordSuccessfulScan(String rootId) async {
    if (_clearing != null) return;
    final revision = _revision;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_scanTimesKey) ?? const [];
    final prefix = '$rootId|';
    final next = saved.where((row) => !row.startsWith(prefix)).toList()
      ..add('$rootId|${DateTime.now().millisecondsSinceEpoch}');
    if (revision == _revision) await prefs.setStringList(_scanTimesKey, next);
  }

  @override
  void dispose() {
    _snapshotSubscription?.cancel();
    _progressSubscription?.cancel();
    super.dispose();
  }
}

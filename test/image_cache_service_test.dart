import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dream_player/services/image_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async => directory = await Directory.systemTemp.createTemp('aln_artwork_'));
  tearDown(() async => directory.delete(recursive: true));
  const url = 'https://image.tmdb.org/t/p/w342/poster.jpg';

  test('offline restart reuses artwork for a different display size', () async {
    var requests = 0;
    final online = ImageCacheService(directory: () async => directory, download: (_) async {
      requests++;
      return Uint8List.fromList([1, 2, 3]);
    });
    final first = await online.fetch(url);
    final restarted = ImageCacheService(directory: () async => directory,
      download: (_) async => throw StateError('offline'));
    final second = await restarted.fetch(url.replaceFirst('w342', 'w185'));
    expect(second?.path, first?.path);
    expect(await second!.readAsBytes(), [1, 2, 3]);
    expect(requests, 1);
  });

  test('online keeps the exact size and offline falls back to the largest', () async {
    final online = ImageCacheService(directory: () async => directory,
      download: (_) async => Uint8List.fromList([1]));
    await online.fetch(url.replaceFirst('w342', 'w185'));
    final large = await online.fetch(url.replaceFirst('w342', 'w780'));
    expect(large?.path, endsWith('w780.img'));

    final offline = ImageCacheService(directory: () async => directory,
      download: (_) async => throw StateError('offline'));
    // w780 renders a w1280 backdrop far better than the w185 thumbnail would.
    final fallback = await offline.fetch(url.replaceFirst('w342', 'w1280'));
    expect(fallback?.path, large?.path);
  });

  test('deduplicates requests and bounds concurrent downloads', () async {
    var active = 0;
    var peak = 0;
    var requests = 0;
    final cache = ImageCacheService(directory: () async => directory, download: (_) async {
      requests++;
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      return Uint8List.fromList([1]);
    });
    await Future.wait([cache.fetch(url), cache.fetch(url),
      for (var index = 0; index < 10; index++) cache.fetch(url.replaceFirst('poster', 'poster$index')),
    ]);
    expect(requests, 11);
    expect(peak, lessThanOrEqualTo(ImageCacheService.maxDownloads));
    expect(await cache.diskSizeBytes(), 11);
  });

  test('clear blocks a late download from repopulating the cache', () async {
    final started = Completer<void>();
    final result = Completer<Uint8List?>();
    final cache = ImageCacheService(directory: () async => directory, download: (_) {
      started.complete();
      return result.future;
    });
    final request = cache.fetch(url);
    await started.future;
    await cache.clear();
    result.complete(Uint8List.fromList([1, 2]));
    expect(await request, isNull);
    expect(await cache.diskSizeBytes(), 0);
  });

  test('clear works before the first read after a restart', () async {
    final first = ImageCacheService(directory: () async => directory,
      download: (_) async => Uint8List.fromList([1, 2]));
    await first.fetch(url);
    final restarted = ImageCacheService(directory: () async => directory);
    await restarted.clear();
    expect(await restarted.diskSizeBytes(), 0);
  });

  test('does not persist authenticated server URLs or oversized responses', () async {
    var requests = 0;
    final cache = ImageCacheService(directory: () async => directory, download: (_) async {
      requests++;
      return Uint8List(ImageCacheService.maxImageBytes + 1);
    });
    expect(await cache.fetch('https://nas.test/poster.jpg?token=private'), isNull);
    expect(await cache.fetch('https://image.tmdb.org/t/p/w342/../secret.jpg'), isNull);
    expect(requests, 0);
    expect(await cache.fetch(url), isNull);
    expect(await cache.diskSizeBytes(), 0);
  });
}

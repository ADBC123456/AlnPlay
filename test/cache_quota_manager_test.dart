import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dream_player/services/cache_quota_manager.dart';

void main() {
  late Directory directory;
  late CacheQuotaManager quota;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('alnplay_quota_test_');
    quota = CacheQuotaManager(roots: [directory], initialLimitBytes: 12);
    await quota.initialize();
  });
  tearDown(() async {
    quota.dispose();
    await directory.delete(recursive: true);
  });
  File file(String name) => File('${directory.path}/$name');

  test('active subtitle group cannot be evicted or overwritten', () async {
    await quota.setLimit(100);
    final subtitle = file('sidecar_subs/show.srt');
    expect(await quota.write(subtitle, [1, 2]), isTrue);
    quota.beginPlayback();
    expect(await quota.write(subtitle, [3, 4]), isFalse);
    expect(await quota.clear(), 0);
    expect(quota.pendingClear, isTrue);
    expect(await subtitle.readAsBytes(), [1, 2]);
    await quota.endPlayback();
    expect(await subtitle.exists(), isFalse);
    expect(quota.pendingClear, isFalse);
  });

  test(
    'evicts least recently used, preserving recently read content',
    () async {
      await quota.write(file('a'), [1, 2, 3, 4]);
      await quota.write(file('b'), [1, 2, 3, 4]);
      await quota.write(file('c'), [1, 2, 3, 4]);
      await file('a').setLastModified(DateTime(2000));
      // Restart to verify LRU is persisted through file timestamps.
      quota.dispose();
      quota = CacheQuotaManager(roots: [directory], initialLimitBytes: 12);
      await quota.write(file('d'), [1, 2, 3, 4]);
      expect(await file('a').exists(), isFalse);
      expect(await file('b').exists(), isTrue);
      expect(await quota.size(), 12);
    },
  );

  test(
    'concurrent writes share budget and oversized item is skipped',
    () async {
      final results = await Future.wait([
        quota.write(file('a'), List.filled(8, 1)),
        quota.write(file('b'), List.filled(8, 2)),
      ]);
      expect(results, [true, true]);
      expect(await quota.size(), 8);
      expect(await quota.write(file('huge'), List.filled(13, 0)), isFalse);
      expect(await file('huge').exists(), isFalse);
    },
  );

  test('decreasing limit protects leases and clears on release', () async {
    await quota.write(file('playing'), List.filled(8, 0));
    quota.lease(file('playing').path);
    await quota.setLimit(4);
    expect(quota.overLimit, isTrue);
    expect(await file('playing').exists(), isTrue);
    expect(await quota.write(file('new'), [1]), isFalse);
    await quota.release(file('playing').path);
    expect(await quota.size(), 0);
  });

  test(
    'clear defers leased content and unlimited permits large items',
    () async {
      await quota.setLimit(0);
      await quota.write(file('large'), List.filled(32, 0));
      quota.lease(file('large').path);
      expect(await quota.clear(), 0);
      await quota.release(file('large').path);
      expect(await file('large').exists(), isFalse);
      expect(quota.evictionRevision, greaterThan(0));
    },
  );

  test(
    'replacement reserves old and temporary bytes; outside roots rejected',
    () async {
      await quota.write(file('a'), List.filled(8, 1));
      quota.lease(file('a').path);
      expect(await quota.write(file('a'), List.filled(8, 2)), isFalse);
      expect(await file('a').readAsBytes(), List.filled(8, 1));
      expect(
        await quota.write(File('${directory.path}/../not-cache'), [1]),
        isFalse,
      );
    },
  );
}

import 'dart:io';

import 'package:filesystemv/src/shadowed_path_index.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ShadowedPathIndex', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('shadowed-index-test-');
    });

    tearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('contains exact in-memory entries', () {
      final index = ShadowedPathIndex(
        storageRoot: temp.path,
        maxInMemoryEntries: 10,
      )..add('/a/b');
      expect(index.containsExact('/a/b'), isTrue);
      expect(index.containsExact('/a/c'), isFalse);
      expect(index.inMemoryCount, 1);
      expect(index.spilledEntryCount, 0);
    });

    test('contains ancestor entries', () {
      final index = ShadowedPathIndex(
        storageRoot: temp.path,
        maxInMemoryEntries: 10,
      )..add('/root/dir');
      expect(index.containsAncestor('/root/dir/file.txt'), isTrue);
      expect(index.containsAncestor('/root/other/file.txt'), isFalse);
    });

    test('spills entries to disk when in-memory limit exceeded', () {
      final index = ShadowedPathIndex(
        storageRoot: temp.path,
        maxInMemoryEntries: 2,
      );

      for (var i = 0; i < 100; i++) {
        index.add('/p/$i');
      }

      expect(index.inMemoryCount, lessThanOrEqualTo(2));
      expect(index.spilledEntryCount, greaterThan(0));
      expect(
        Directory(p.join(temp.path, '.filesystemv_shadow_index')).existsSync(),
        isTrue,
      );
      final indexDir =
          Directory(p.join(temp.path, '.filesystemv_shadow_index'));
      final idxFiles = indexDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.idx'))
          .toList();
      expect(idxFiles, isNotEmpty);
      expect(idxFiles.any((f) => f.lengthSync() > 0), isTrue);
    });

    test('finds spilled entries from disk', () {
      final index = ShadowedPathIndex(
        storageRoot: temp.path,
        maxInMemoryEntries: 0,
        maxLookupCacheEntries: 2,
      );

      const spilled = '/deep/path/value';
      index
        ..add(spilled)
        // Evict the add-time lookup cache entry.
        ..add('/other')
        ..add('/another');

      expect(index.containsExact(spilled), isTrue);
      expect(index.spilledEntryCount, greaterThan(0));
      expect(index.debugDiskScanCount, greaterThan(0));
    });

    test('lookup cache avoids repeated disk scans for same key', () {
      final index = ShadowedPathIndex(
        storageRoot: temp.path,
        maxInMemoryEntries: 0,
        maxLookupCacheEntries: 4,
      );

      const spilled = '/cached/spilled/path';
      index
        ..add(spilled)
        ..add('/evict-1')
        ..add('/evict-2')
        ..add('/evict-3')
        ..add('/evict-4');

      expect(index.containsExact(spilled), isTrue);
      final scansAfterFirstLookup = index.debugDiskScanCount;
      expect(scansAfterFirstLookup, greaterThan(0));

      expect(index.containsExact(spilled), isTrue);
      expect(index.debugDiskScanCount, scansAfterFirstLookup);
    });

    test('negative lookup is cached and avoids repeated disk scans', () {
      final index = ShadowedPathIndex(
        storageRoot: temp.path,
        maxInMemoryEntries: 0,
        maxLookupCacheEntries: 16,
      );

      for (var i = 0; i < 50; i++) {
        index.add('/spilled/$i');
      }

      const missing = '/spilled/missing-value';
      expect(index.containsExact(missing), isFalse);
      final firstScanCount = index.debugDiskScanCount;
      expect(firstScanCount, greaterThanOrEqualTo(0));

      expect(index.containsExact(missing), isFalse);
      expect(index.debugDiskScanCount, firstScanCount);
    });

    test('offset index loads once per bucket and is reused', () {
      final index = ShadowedPathIndex(
        storageRoot: temp.path,
        maxInMemoryEntries: 0,
        maxLookupCacheEntries: 32,
      );

      const first = '/offsets/a';
      final second = _findSameBucketPath(first, '/offsets/b');
      index
        ..add(first)
        ..add(second);
      for (var i = 0; i < 64; i++) {
        index.add('/offsets/evict-$i');
      }

      expect(index.containsExact(first), isTrue);
      final loadsAfterFirst = index.debugOffsetIndexLoadCount;
      expect(loadsAfterFirst, greaterThan(0));

      expect(index.containsExact(second), isTrue);
      expect(index.debugOffsetIndexLoadCount, loadsAfterFirst);
    });
  });
}

String _findSameBucketPath(String seed, String prefix) {
  final targetBucket = seed.hashCode & 0xFF;
  for (var i = 0; i < 100000; i++) {
    final candidate = '$prefix-$i';
    if ((candidate.hashCode & 0xFF) == targetBucket) {
      return candidate;
    }
  }
  throw StateError('Unable to find same-bucket path');
}

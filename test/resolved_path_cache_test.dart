import 'package:filesystemv/src/resolved_path_cache.dart';
import 'package:test/test.dart';

void main() {
  group('ResolvedPathCache', () {
    test('returns null for missing keys', () {
      final cache = ResolvedPathCache(maxEntries: 4);
      expect(cache.get('/missing'), isNull);
    });

    test('stores and returns values', () {
      final cache = ResolvedPathCache(maxEntries: 4)..put('/a', '/v/a');
      expect(cache.get('/a'), '/v/a');
    });

    test('evicts least recently used entry when max size exceeded', () {
      final cache = ResolvedPathCache(maxEntries: 2)
        ..put('/a', '/v/a')
        ..put('/b', '/v/b');
      expect(cache.get('/a'), '/v/a'); // refresh a as MRU
      cache.put('/c', '/v/c');

      expect(cache.get('/a'), '/v/a');
      expect(cache.get('/b'), isNull);
      expect(cache.get('/c'), '/v/c');
      expect(cache.entryCount, 2);
    });

    test('invalidates exact path entries', () {
      final cache = ResolvedPathCache(maxEntries: 4)..put('/a/b', '/v/a/b');
      expect(cache.get('/a/b'), '/v/a/b');

      cache.invalidate('/a/b');
      expect(cache.get('/a/b'), isNull);
    });

    test('invalidates descendants when parent path is invalidated', () {
      final cache = ResolvedPathCache(maxEntries: 8)
        ..put('/a', '/v/a')
        ..put('/a/b', '/v/a/b')
        ..put('/a/b/c', '/v/a/b/c')
        ..put('/x/y', '/v/x/y')
        ..invalidate('/a');

      expect(cache.get('/a'), isNull);
      expect(cache.get('/a/b'), isNull);
      expect(cache.get('/a/b/c'), isNull);
      expect(cache.get('/x/y'), '/v/x/y');
    });

    test('unrelated invalidation does not evict other subtrees', () {
      final cache = ResolvedPathCache(maxEntries: 8)
        ..put('/a/b', '/v/a/b')
        ..put('/x/y', '/v/x/y')
        ..invalidate('/x');

      expect(cache.get('/a/b'), '/v/a/b');
      expect(cache.get('/x/y'), isNull);
    });

    test('invalidation is lazy and does not eagerly purge cache', () {
      final cache = ResolvedPathCache(maxEntries: 2000);
      for (var i = 0; i < 1000; i++) {
        cache.put('/root/$i/file.txt', '/v/root/$i/file.txt');
      }
      expect(cache.entryCount, 1000);

      cache.invalidate('/root');
      // Epoch-based invalidation keeps O(1) invalidation by deferring eviction.
      expect(cache.entryCount, 1000);
      expect(cache.get('/root/0/file.txt'), isNull);
    });
  });
}

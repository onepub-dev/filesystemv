import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

final class ShadowedPathIndex {
  ShadowedPathIndex({
    required String storageRoot,
    this.maxInMemoryEntries = 4096,
    this.maxLookupCacheEntries = 2048,
  }) : _indexDir = Directory(p.join(storageRoot, '.filesystemv_shadow_index')) {
    _indexDir.createSync(recursive: true);
  }

  final int maxInMemoryEntries;
  final int maxLookupCacheEntries;
  final Directory _indexDir;
  final _inMemory = <String>{};
  final _spilledBuckets = <int>{};
  final _lookupCache = <String, bool>{};
  final _bucketBloom = <int, _BucketBloom>{};
  final _offsetIndexCache = <int, Map<int, List<int>>>{};
  static const _maxOffsetIndexBucketsInMemory = 32;
  var _spilledEntryCount = 0;
  var _debugDiskScanCount = 0;
  var _debugOffsetIndexLoadCount = 0;

  void add(String path) {
    if (_inMemory.contains(path)) {
      _putLookup(path, true);
      return;
    }
    if (_inMemory.length < maxInMemoryEntries) {
      _inMemory.add(path);
      _putLookup(path, true);
      return;
    }
    _appendToSpill(path);
    _putLookup(path, true);
  }

  bool containsExact(String path) {
    if (_inMemory.contains(path)) {
      _putLookup(path, true);
      return true;
    }
    final cached = _touchLookup(path);
    if (cached != null) {
      return cached;
    }
    final found = _scanBucketForPath(path);
    _putLookup(path, found);
    return found;
  }

  bool containsAncestor(String path) {
    var cursor = path;
    while (true) {
      if (containsExact(cursor)) {
        return true;
      }
      final parent = p.dirname(cursor);
      if (parent == cursor) {
        return false;
      }
      cursor = parent;
    }
  }

  int get inMemoryCount => _inMemory.length;
  int get spilledEntryCount => _spilledEntryCount;
  int get debugDiskScanCount => _debugDiskScanCount;
  int get debugOffsetIndexLoadCount => _debugOffsetIndexLoadCount;

  File _bucketFile(String path) {
    final bucket = path.hashCode & 0xFF;
    return File(p.join(_indexDir.path, '$bucket.bin'));
  }

  File _bucketIndexFile(String path) {
    final bucket = path.hashCode & 0xFF;
    return File(p.join(_indexDir.path, '$bucket.idx'));
  }

  void _appendToSpill(String path) {
    final file = _bucketFile(path);
    final indexFile = _bucketIndexFile(path);
    final bucket = path.hashCode & 0xFF;
    _spilledBuckets.add(bucket);
    final hash = _fingerprint(path);
    (_bucketBloom[bucket] ??= _BucketBloom()).add(hash);
    final raf = file.openSync(mode: FileMode.append);
    final idx = indexFile.openSync(mode: FileMode.append);
    try {
      final bytes = utf8.encode(path);
      final offset = raf.positionSync();
      final header = ByteData(12)
        ..setUint32(0, bytes.length, Endian.little)
        ..setUint64(4, hash, Endian.little);
      raf
        ..writeFromSync(header.buffer.asUint8List())
        ..writeFromSync(bytes);
      final indexRow = ByteData(16)
        ..setUint64(0, hash, Endian.little)
        ..setUint64(8, offset, Endian.little);
      idx.writeFromSync(indexRow.buffer.asUint8List());
      _spilledEntryCount++;
      final cachedBucket = _offsetIndexCache[bucket];
      if (cachedBucket != null) {
        (cachedBucket[hash] ??= <int>[]).add(offset);
      }
    } finally {
      raf.closeSync();
      idx.closeSync();
    }
  }

  bool _scanBucketForPath(String path) {
    final bucket = path.hashCode & 0xFF;
    if (!_spilledBuckets.contains(bucket)) {
      return false;
    }
    final hash = _fingerprint(path);
    final bloom = _bucketBloom[bucket];
    if (bloom != null && !bloom.mightContain(hash)) {
      return false;
    }
    final file = _bucketFile(path);
    if (!file.existsSync()) {
      return false;
    }
    final offsets = _offsetsFor(bucket, path, hash);
    if (offsets.isEmpty) {
      return false;
    }
    _debugDiskScanCount++;
    final raf = file.openSync();
    try {
      final target = utf8.encode(path);
      for (final offset in offsets) {
        raf.setPositionSync(offset);
        final headerBytes = raf.readSync(12);
        if (headerBytes.length != 12) {
          return false;
        }
        final view = ByteData.sublistView(Uint8List.fromList(headerBytes));
        final len = view.getUint32(0, Endian.little);
        final entryHash = view.getUint64(4, Endian.little);
        if (entryHash != hash) {
          continue;
        }
        final payload = raf.readSync(len);
        if (payload.length != len) {
          return false;
        }
        if (_bytesEqual(payload, target)) {
          return true;
        }
      }
      return false;
    } finally {
      raf.closeSync();
    }
  }

  List<int> _offsetsFor(int bucket, String path, int hash) {
    final cached = _offsetIndexCache.remove(bucket);
    if (cached != null) {
      _offsetIndexCache[bucket] = cached;
      return cached[hash] ?? const <int>[];
    }

    final indexFile = _bucketIndexFile(path);
    if (!indexFile.existsSync()) {
      return const <int>[];
    }

    final map = <int, List<int>>{};
    _debugOffsetIndexLoadCount++;
    final raf = indexFile.openSync();
    try {
      while (raf.positionSync() < raf.lengthSync()) {
        final row = raf.readSync(16);
        if (row.length != 16) {
          break;
        }
        final view = ByteData.sublistView(Uint8List.fromList(row));
        final entryHash = view.getUint64(0, Endian.little);
        final offset = view.getUint64(8, Endian.little);
        (map[entryHash] ??= <int>[]).add(offset);
      }
    } finally {
      raf.closeSync();
    }

    _offsetIndexCache[bucket] = map;
    if (_offsetIndexCache.length > _maxOffsetIndexBucketsInMemory) {
      _offsetIndexCache.remove(_offsetIndexCache.keys.first);
    }
    return map[hash] ?? const <int>[];
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  bool? _touchLookup(String path) {
    final existing = _lookupCache.remove(path);
    if (existing == null) {
      return null;
    }
    _lookupCache[path] = existing;
    return existing;
  }

  void _putLookup(String path, bool value) {
    _lookupCache.remove(path);
    _lookupCache[path] = value;
    if (_lookupCache.length > maxLookupCacheEntries) {
      _lookupCache.remove(_lookupCache.keys.first);
    }
  }

  static int _fingerprint(String path) {
    const prime = 0x100000001b3;
    // this library doesn't support js.
    // ignore: avoid_js_rounded_ints
    var hash = 0xcbf29ce484222325;
    for (final unit in path.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash;
  }
}

final class _BucketBloom {
  final _bits = Uint64List(32); // 2048 bits.

  void add(int hash) {
    for (final index in _indexes(hash)) {
      final word = index >> 6;
      final bit = index & 63;
      _bits[word] |= 1 << bit;
    }
  }

  bool mightContain(int hash) {
    for (final index in _indexes(hash)) {
      final word = index >> 6;
      final bit = index & 63;
      if ((_bits[word] & (1 << bit)) == 0) {
        return false;
      }
    }
    return true;
  }

  static List<int> _indexes(int hash) {
    final h1 = hash & 0x7FFFFFFF;
    final h2 = ((hash >> 32) ^ hash) & 0x7FFFFFFF;
    final h3 = ((h1 * 31) ^ (h2 * 17)) & 0x7FFFFFFF;
    return <int>[h1 % 2048, h2 % 2048, h3 % 2048];
  }
}

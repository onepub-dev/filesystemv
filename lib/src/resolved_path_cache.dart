import 'package:path/path.dart' as p;

final class ResolvedPathCache {
  ResolvedPathCache({this.maxEntries = 4096});

  final int maxEntries;
  final _entries = <String, _ResolvedEntry>{};
  final _prefixEpoch = <String, int>{};
  var _epoch = 0;

  String? get(String key) {
    final entry = _entries.remove(key);
    if (entry == null) {
      return null;
    }
    if (_isStale(key, entry.stamp)) {
      return null;
    }
    _entries[key] = entry;
    return entry.value;
  }

  void put(String key, String value) {
    _entries.remove(key);
    _entries[key] = _ResolvedEntry(value: value, stamp: _epoch);
    if (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  void invalidate(String path) {
    _prefixEpoch[path] = ++_epoch;
  }

  int get entryCount => _entries.length;

  bool _isStale(String path, int entryStamp) {
    var cursor = path;
    while (true) {
      final epoch = _prefixEpoch[cursor];
      if (epoch != null && epoch > entryStamp) {
        return true;
      }
      final parent = p.dirname(cursor);
      if (parent == cursor) {
        break;
      }
      cursor = parent;
    }
    return false;
  }
}

final class _ResolvedEntry {
  const _ResolvedEntry({required this.value, required this.stamp});

  final String value;
  final int stamp;
}

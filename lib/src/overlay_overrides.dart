import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'guarded_entities.dart';
import 'resolved_path_cache.dart';
import 'shadowed_path_index.dart';
import 'store_path_guard.dart';

final class OverlayOverrides extends IOOverrides {
  OverlayOverrides({
    required this.storageRoot,
    List<String>? virtualizedRoots,
    int maxResolvedPathCacheEntries = 4096,
    int maxShadowedInMemoryEntries = 4096,
    int maxShadowedLookupCacheEntries = 2048,
  })  : _virtualizedRoots = (virtualizedRoots ?? const <String>[])
            .map(normalizePath)
            .toList(growable: false),
        _shadowedPaths = ShadowedPathIndex(
          storageRoot: checkStore(storageRoot),
          maxInMemoryEntries: maxShadowedInMemoryEntries,
          maxLookupCacheEntries: maxShadowedLookupCacheEntries,
        ),
        _resolvedReadPathCache =
            ResolvedPathCache(maxEntries: maxResolvedPathCacheEntries);

  final String storageRoot;
  final List<String> _virtualizedRoots;
  final ShadowedPathIndex _shadowedPaths;
  final ResolvedPathCache _resolvedReadPathCache;

  bool get _virtualizeAll => _virtualizedRoots.isEmpty;

  static String normalizePath(String value) => p.normalize(p.absolute(value));

  @override
  File createFile(String path) {
    final realPath = normalizePath(path);
    _checkDirectStorePath(realPath);
    if (!_shouldVirtualizeNormalized(realPath)) {
      return GuardedFile(
          this, super.createFile(_isStorePath(realPath) ? realPath : path));
    }

    final virtualPath = _toVirtualPath(realPath);
    _checkStorePath(virtualPath);
    if (!_isShadowed(realPath)) {
      _materializeFile(realPath, virtualPath);
      _markShadowed(realPath);
    }
    return GuardedFile(this, super.createFile(virtualPath));
  }

  @override
  Directory createDirectory(String path) {
    final realPath = normalizePath(path);
    _checkDirectStorePath(realPath);
    if (!_shouldVirtualizeNormalized(realPath)) {
      return GuardedDirectory(this,
          super.createDirectory(_isStorePath(realPath) ? realPath : path));
    }

    final virtualPath = _toVirtualPath(realPath);
    _resolvedReadPathCache.invalidate(virtualPath);
    _checkStorePath(virtualPath);
    if (!_isShadowed(realPath)) {
      _materializeDirectory(realPath, virtualPath);
    }
    return GuardedDirectory(this, super.createDirectory(virtualPath));
  }

  @override
  Link createLink(String path) {
    final realPath = normalizePath(path);
    if (!_isStorePath(realPath) && !_shouldVirtualizeNormalized(realPath)) {
      return GuardedLink(this, super.createLink(path));
    }

    // Returning a native Link would allow create/update to install arbitrary
    // host targets, including after a File handle has already been obtained.
    throw FileSystemException(
      'Virtualized Link handles are not supported',
      path,
    );
  }

  @override
  Directory getCurrentDirectory() =>
      createDirectory(super.getCurrentDirectory().path);

  @override
  Directory getSystemTempDirectory() =>
      createDirectory(super.getSystemTempDirectory().path);

  @override
  void setCurrentDirectory(String path) => throw FileSystemException(
        'Changing the current directory is not supported in an overlay',
        path,
      );

  /// Recheck retained handles before native operations.
  void validateHandlePath(String path) =>
      _checkDirectStorePath(normalizePath(path));

  /// The store is a terminating, guarded root for derived parent handles.
  Directory parentOf(String path) {
    final normalized = normalizePath(path);
    validateHandlePath(normalized);
    return createDirectory(
        normalized == storageRoot ? storageRoot : p.dirname(normalized));
  }

  /// A deleted directory also hides host descendants not yet materialized.
  void didDelete(String path) {
    final normalized = normalizePath(path);
    if (_isStorePath(normalized)) {
      _shadowedPaths.add(normalized);
      _resolvedReadPathCache.invalidate(normalized);
    }
  }

  @override
  Future<FileStat> stat(String path) => super.stat(_resolveForRead(path));

  @override
  FileStat statSync(String path) => super.statSync(_resolveForRead(path));

  @override
  Future<bool> fseIdentical(String path1, String path2) => super.fseIdentical(
        _resolveForRead(path1),
        _resolveForRead(path2),
      );

  @override
  bool fseIdenticalSync(String path1, String path2) =>
      super.fseIdenticalSync(_resolveForRead(path1), _resolveForRead(path2));

  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      Future<FileSystemEntityType>.value(fseGetTypeSync(path, followLinks));

  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      super.fseGetTypeSync(_resolveForRead(path), followLinks);

  @override
  Stream<FileSystemEvent> fsWatch(String path, int events, bool recursive) =>
      super.fsWatch(_resolveForRead(path), events, recursive);

  bool _shouldVirtualizeNormalized(String path) {
    if (_isStorePath(path)) {
      return false;
    }
    if (_virtualizeAll) {
      return true;
    }

    for (final root in _virtualizedRoots) {
      if (path == root || p.isWithin(root, path)) {
        return true;
      }
    }
    return false;
  }

  String _resolveForRead(String rawPath) {
    final realPath = normalizePath(rawPath);
    _checkDirectStorePath(realPath);
    if (!_shouldVirtualizeNormalized(realPath)) {
      // Direct store paths must not share logical-path cache entries, which
      // can still point to host data before first materialization.
      return _isStorePath(realPath) ? realPath : rawPath;
    }
    final virtualPath = _toVirtualPath(realPath);
    // Validate even cache hits: persisted store contents may have changed.
    _checkStorePath(virtualPath);
    final cached = _resolvedReadPathCache.get(virtualPath);
    if (cached != null) {
      return cached;
    }

    if (_isShadowed(realPath)) {
      _resolvedReadPathCache.put(virtualPath, virtualPath);
      return virtualPath;
    }
    final resolved =
        super.fseGetTypeSync(virtualPath, true) == FileSystemEntityType.notFound
            ? realPath
            : virtualPath;
    _resolvedReadPathCache.put(virtualPath, resolved);
    return resolved;
  }

  void _markShadowed(String realPath) {
    final virtualPath = _toVirtualPath(realPath);
    _shadowedPaths.add(virtualPath);
    _resolvedReadPathCache.invalidate(virtualPath);
  }

  bool _isShadowed(String realPath) =>
      _shadowedPaths.containsAncestor(_toVirtualPath(realPath));

  void _materializeFile(String realPath, String virtualPath) {
    final virtualFile = super.createFile(virtualPath);
    if (virtualFile.existsSync()) {
      return;
    }

    virtualFile.parent.createSync(recursive: true);
    final realFile = super.createFile(realPath);
    if (realFile.existsSync()) {
      realFile.copySync(virtualPath);
    }
  }

  void _materializeDirectory(String realPath, String virtualPath) {
    final virtualDirectory = super.createDirectory(virtualPath);
    if (virtualDirectory.existsSync()) {
      return;
    }

    final realDirectory = super.createDirectory(realPath);
    if (!realDirectory.existsSync()) {
      return;
    }
    virtualDirectory.createSync(recursive: true);
  }

  bool _isStorePath(String path) {
    if (path == storageRoot || p.isWithin(storageRoot, path)) {
      return true;
    }
    // Resolve the nearest existing ancestor to detect aliases, including when
    // the final file does not exist yet. Native handles avoid recursive hooks.
    final missing = <String>[];
    var cursor = path;
    while (
        super.fseGetTypeSync(cursor, false) == FileSystemEntityType.notFound) {
      missing.insert(0, p.basename(cursor));
      final parent = p.dirname(cursor);
      if (parent == cursor) {
        return false;
      }
      cursor = parent;
    }
    String canonical;
    try {
      canonical = super.createDirectory(cursor).resolveSymbolicLinksSync();
    } on FileSystemException {
      // A dangling outside link cannot currently lead into the store.
      return false;
    }
    final resolved = p.joinAll([canonical, ...missing]);
    return resolved == storageRoot || p.isWithin(storageRoot, resolved);
  }

  void _checkDirectStorePath(String path) {
    if (_isStorePath(path)) {
      _checkStorePath(path);
    }
  }

  void _checkStorePath(String path) {
    if (!_isStorePath(path)) {
      throw FileSystemException('Path is outside the overlay store', path);
    }
    checkStorePath(
      path,
      getTypeWithoutFollowingLinks: (path) => super.fseGetTypeSync(path, false),
    );
  }

  String _toVirtualPath(String realPath) {
    var normalized = realPath;
    if (p.style == p.Style.windows) {
      normalized = normalized.replaceAll(':', '');
      if (normalized.startsWith(r'\')) {
        normalized = normalized.substring(1);
      }
      return p.join(storageRoot, normalized);
    }

    if (normalized.startsWith('/')) {
      normalized = normalized.substring(1);
    }
    return p.join(storageRoot, normalized);
  }
}

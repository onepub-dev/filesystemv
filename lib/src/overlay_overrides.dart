import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'resolved_path_cache.dart';
import 'shadowed_path_index.dart';

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
          storageRoot: storageRoot,
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
    if (!_shouldVirtualizeNormalized(realPath)) {
      return super.createFile(path);
    }

    _markShadowed(realPath);
    final virtualPath = _toVirtualPath(realPath);
    _materializeFile(realPath, virtualPath);
    return super.createFile(virtualPath);
  }

  @override
  Directory createDirectory(String path) {
    final realPath = normalizePath(path);
    if (!_shouldVirtualizeNormalized(realPath)) {
      return super.createDirectory(path);
    }

    _resolvedReadPathCache.invalidate(realPath);
    final virtualPath = _toVirtualPath(realPath);
    _materializeDirectory(realPath, virtualPath);
    return super.createDirectory(virtualPath);
  }

  @override
  Link createLink(String path) {
    final realPath = normalizePath(path);
    if (!_shouldVirtualizeNormalized(realPath)) {
      return super.createLink(path);
    }

    _markShadowed(realPath);
    final virtualPath = _toVirtualPath(realPath);
    _materializeLink(realPath, virtualPath);
    return super.createLink(virtualPath);
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
    if (path == storageRoot || p.isWithin(storageRoot, path)) {
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
    final cached = _resolvedReadPathCache.get(realPath);
    if (cached != null) {
      return cached;
    }

    if (!_shouldVirtualizeNormalized(realPath)) {
      _resolvedReadPathCache.put(realPath, rawPath);
      return rawPath;
    }

    final virtualPath = _toVirtualPath(realPath);
    if (_isShadowed(realPath)) {
      _resolvedReadPathCache.put(realPath, virtualPath);
      return virtualPath;
    }
    final resolved =
        super.fseGetTypeSync(virtualPath, true) == FileSystemEntityType.notFound
            ? realPath
            : virtualPath;
    _resolvedReadPathCache.put(realPath, resolved);
    return resolved;
  }

  void _markShadowed(String realPath) {
    _shadowedPaths.add(realPath);
    _resolvedReadPathCache.invalidate(realPath);
  }

  bool _isShadowed(String realPath) =>
      _shadowedPaths.containsAncestor(realPath);

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

  void _materializeLink(String realPath, String virtualPath) {
    final virtualLink = super.createLink(virtualPath);
    final virtualType = super.fseGetTypeSync(virtualPath, false);
    if (virtualType == FileSystemEntityType.link) {
      return;
    }

    final realLink = super.createLink(realPath);
    final realType = super.fseGetTypeSync(realPath, false);
    if (realType != FileSystemEntityType.link) {
      return;
    }

    virtualLink.parent.createSync(recursive: true);
    virtualLink.createSync(realLink.targetSync(), recursive: true);
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

import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolve aliases above the store, but never resolve the store itself.
///
/// System temp paths can contain platform aliases (for example /var on macOS).
/// Missing parent directories are appended to the nearest existing parent's
/// canonical path and are subsequently checked before creation.
String canonicalStorePath(String path) {
  final absolute = p.normalize(p.absolute(path));
  final missing = <String>[];
  var parent = p.dirname(absolute);
  while (FileSystemEntity.typeSync(parent, followLinks: false) ==
      FileSystemEntityType.notFound) {
    missing.insert(0, p.basename(parent));
    final next = p.dirname(parent);
    if (next == parent) {
      throw FileSystemException('Cannot resolve overlay store parent', parent);
    }
    parent = next;
  }
  final canonicalParent = Directory(parent).resolveSymbolicLinksSync();
  final canonical = parent == absolute
      ? canonicalParent
      : p.joinAll([canonicalParent, ...missing, p.basename(absolute)]);
  checkStorePath(canonical);
  return canonical;
}

/// Native handles follow symlinks, so store paths must not contain any.
void checkStorePath(
  String path, {
  FileSystemEntityType Function(String)? getTypeWithoutFollowingLinks,
}) {
  final type = getTypeWithoutFollowingLinks ??
      (String path) => FileSystemEntity.typeSync(path, followLinks: false);
  final absolute = p.normalize(p.absolute(path));
  final components = <String>[];
  var cursor = absolute;
  while (true) {
    components.add(cursor);
    final parent = p.dirname(cursor);
    if (parent == cursor) {
      break;
    }
    cursor = parent;
  }
  // Check parents first: even a no-follow stat follows intermediate links.
  for (final component in components.reversed) {
    if (type(component) == FileSystemEntityType.link) {
      throw FileSystemException(
        'Symbolic links are not supported in the overlay store',
        component,
      );
    }
  }
}

/// Reject persisted data: portable dart:io cannot identify shared hardlinks.
String checkStore(String storageRoot) {
  checkStorePath(storageRoot);
  final directory = Directory(storageRoot);
  if (directory.existsSync()) {
    if (directory.listSync(followLinks: false).isNotEmpty) {
      throw FileSystemException(
        'Overlay stores must be empty before use',
        storageRoot,
      );
    }
  }
  return storageRoot;
}

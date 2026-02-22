import 'dart:async';
import 'dart:io';

import 'overlay_overrides.dart';

/// Runs [action] within a virtualized file-system overlay.
///
/// [action] receives the path to the virtual store root, which can be used as
/// a process working directory.
///
/// The returned string is that same virtual store root path.
Future<String> withVFileSystem(
  FutureOr<void> Function(String virtualRoot) action, {
  List<String>? paths,
  String? store,
}) async {
  final createdTemp = store == null;
  final storageDirectory = createdTemp
      ? Directory.systemTemp.createTempSync('filesystemv-')
      : Directory(store);
  if (!storageDirectory.existsSync()) {
    storageDirectory.createSync(recursive: true);
  }

  final overlay = OverlayOverrides(
    storageRoot: OverlayOverrides.normalizePath(storageDirectory.path),
    virtualizedRoots: paths,
  );

  try {
    await IOOverrides.runWithIOOverrides<Future<void>>(
      () => Future.sync(() => action(storageDirectory.path)),
      overlay,
    );
    return storageDirectory.path;
  } finally {
    if (createdTemp && storageDirectory.existsSync()) {
      storageDirectory.deleteSync(recursive: true);
    }
  }
}

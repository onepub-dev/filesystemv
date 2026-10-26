import 'dart:async';
import 'dart:io';

import 'overlay_overrides.dart';
import 'store_path_guard.dart';

/// Runs [action] within a virtualized file-system overlay.
///
/// [action] receives the path to the virtual store root, which can be used as
/// a process working directory.
///
/// The returned string is that same virtual store root path.
///
/// Virtualized [Link] handles are unsupported and throw [FileSystemException].
/// Ancestors above the store are canonicalized to support system temp aliases.
/// The store itself must be free of symbolic links; custom stores must be empty
/// before entry (persisted hardlinks cannot be safely identified portably).
/// Copy, rename and directory createTemp operations on overlay handles throw
/// before mutation. Changing Directory.current is also unsupported; reading it
/// returns a guarded overlay directory. Derived handles remain guarded.
/// Walking parents terminates at the guarded store root (its parent is itself).
/// Deletions remain visible across new handles, including deleted descendants.
/// Nested calls use independent stores and read from the host, not the outer
/// overlay. Internal setup and cleanup use native IO; each user callback still
/// runs under its own overlay, and returning restores the caller's overlay.
/// File/Directory/Link.fromRawPath constructors bypass IOOverrides and must not
/// be used for protected operations. A custom store must remain exclusively
/// controlled by the caller for the duration of [action]. Do not change store
/// paths through pre-existing native handles or other processes: path checks
/// cannot prevent concurrent replacement between validation and native access.
/// This is an IOOverrides overlay, not a sandbox for untrusted code or
/// processes.
Future<String> withVFileSystem(
  FutureOr<void> Function(String virtualRoot) action, {
  List<String>? paths,
  String? store,
}) =>
    IOOverrides.runWithIOOverrides<Future<String>>(
      () => _withNativeSetup(action, paths: paths, store: store),
      _NativeOverrides(),
    );

// Inherited IOOverrides methods use native dart:io implementations. Keep this
// scope private: runZoned with omitted hooks would inherit the outer overlay.
final class _NativeOverrides extends IOOverrides {}

Future<String> _withNativeSetup(
  FutureOr<void> Function(String virtualRoot) action, {
  List<String>? paths,
  String? store,
}) async {
  final createdTemp = store == null;
  final requestedDirectory = createdTemp
      ? Directory.systemTemp.createTempSync('filesystemv-')
      : Directory(OverlayOverrides.normalizePath(store));
  try {
    final storageDirectory =
        Directory(canonicalStorePath(requestedDirectory.path));
    if (!storageDirectory.existsSync()) {
      storageDirectory.createSync(recursive: true);
    }
    final overlay = OverlayOverrides(
      storageRoot: OverlayOverrides.normalizePath(storageDirectory.path),
      virtualizedRoots: paths,
    );
    await IOOverrides.runWithIOOverrides<Future<void>>(
      () => Future.sync(() => action(storageDirectory.path)),
      overlay,
    );
    return storageDirectory.path;
  } finally {
    if (createdTemp && requestedDirectory.existsSync()) {
      requestedDirectory.deleteSync(recursive: true);
    }
  }
}

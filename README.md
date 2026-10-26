# filesystemv

`filesystemv` provides a write-overlay virtual filesystem for Dart. Reads come
from the host filesystem, while writes are redirected into a virtual store.

This is useful for tests and dry-run workflows where code should behave as if
it writes to disk, without mutating the real machine state.

## Sponsored by OnePub

<img src="images/onepub-logo.svg" alt="OnePub" width="220" />

Help support FileSystemV by supporting [OnePub](https://onepub.dev), the **private dart repository**. OnePub allows you to privately share dart packages between your own
projects or with colleagues.

## API

```dart
Future<String> withVFileSystem(
  FutureOr<void> Function(String virtualRoot) action, {
  List<String>? paths,
  String? store,
})
```

- `virtualRoot`: path to the overlay store directory.
- `paths`: optional list of paths to virtualize. If omitted, all paths are
  virtualized.
- `store`: optional storage directory for overlay data. If omitted, a temp
  directory is created and cleaned up automatically. Ancestors above the store
  are canonicalized, allowing system aliases such as macOS `/var`. The store
  itself must not be a symbolic link. A custom store must be absent or empty
  before entry; retained stores cannot be reopened as overlays. This prevents
  persisted hardlinks from exposing host files through shared inodes.
- Return value: the canonical overlay store path, also passed to the callback.

## Installation

```yaml
dependencies:
  filesystemv: ^0.2.0
```

## Examples

### 1. Virtualize all writes

```dart
import 'dart:io';
import 'package:filesystemv/filesystemv.dart';

Future<void> main() async {
  await withVFileSystem((virtualRoot) {
    final hosts = File('/etc/hosts');
    hosts.writeAsStringSync('127.0.0.1 local-only\n');

    print('Overlay root: $virtualRoot');
    print('Virtual hosts: ${hosts.readAsStringSync()}');
  });
}
```

### 2. Virtualize only selected paths

```dart
import 'dart:io';
import 'package:filesystemv/filesystemv.dart';

Future<void> main() async {
  final cachePath = '${Platform.environment['HOME']}/.pub-cache';
  await withVFileSystem((_) {
    File('$cachePath/notes.txt').writeAsStringSync('virtual cache write\n');
    File('/tmp/real-file.txt').writeAsStringSync('real write\n');
  }, paths: [cachePath]);
}
```

### 3. Keep the overlay store for post-run inspection

```dart
import 'dart:io';
import 'package:filesystemv/filesystemv.dart';

Future<void> main() async {
  final store = Directory.systemTemp.createTempSync('filesystemv-store-');
  final root = await withVFileSystem((_) {
    File('/tmp/report.txt').writeAsStringSync('overlay report');
  }, store: store.path);

  print('Overlay store retained at: $root');
}
```

The retained store is for inspection only. Use a new empty directory for the
next invocation; even regular files in an existing store cause entry to fail
before the callback runs.

### 4. Spawn a process using the virtual store as CWD

```dart
import 'dart:io';
import 'package:filesystemv/filesystemv.dart';

Future<void> main() async {
  await withVFileSystem((virtualRoot) async {
    final report = File('process.txt')..writeAsStringSync('hello world');
    // File.path identifies the materialized file inside the overlay store.
    await Process.run(
      'bash',
      ['-c', r'printf "hello again\n" >> "$1"; cat "$1"', '_', report.path],
      workingDirectory: virtualRoot,
    );
  });
}
```

### 5. Use with `path` and `dcli`

```dart
import 'dart:io';
import 'package:dcli/dcli.dart';
import 'package:filesystemv/filesystemv.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final root = Directory.systemTemp.createTempSync('fsv-demo-');
  final pathToFile = p.join(root.path, 'demo.txt');

  await withVFileSystem((_) {
    pathToFile.write('line-1', newline: '');
    pathToFile.append('line-2', newline: '');
    print(File(pathToFile).readAsStringSync()); // line-1line-2
  });

  print(File(pathToFile).existsSync()); // false
  root.deleteSync(recursive: true);
}
```

### 6. Migrating link operations from 0.1.0

Version 0.2.0 intentionally removes virtualized `Link` support. Constructing a
`Link` for a virtualized path or a path inside the store throws
`FileSystemException`, even for read-only operations such as `targetSync()`.
Use regular files and directories for overlay output. Links outside explicitly
selected `paths` still support creation, update, reading, and deletion on the
real filesystem.

`File.copy`, `File.rename`, `Directory.rename`, and `Link.rename` (and their
synchronous variants) are unsupported on handles returned inside the overlay.
They throw `FileSystemException` before mutation, including when both paths
are outside the selected scope or the destination is already a mapped path.
For regular file contents, read the source and write to a separately constructed
destination `File`; that constructor applies the selected-path policy.

`Directory.createTemp` and `createTempSync` are also unsupported on overlay
handles, because their prefix can redirect native creation. Create an explicit
directory with `Directory(path).create()` or `createSync()` instead.
`Directory.current` and `Directory.systemTemp` return guarded directories;
assigning to `Directory.current` inside the
callback is unsupported. Set the working directory before entering the overlay
if relative paths need a different base.

## Additional Use Cases

- Protecting host state in integration tests that call third-party libraries.
- Running migration tools in dry-run mode while preserving real data.
- Safe experimentation with config rewrites in CI smoke tests.
- Capturing generated artifacts from tools in a temporary isolated workspace.

## Example App

A comprehensive runnable example is available at:

- `example/filesystemv_example.dart`

Run it with:

```bash
dart run example/filesystemv_example.dart
```

## Benchmark Harness

Run the local micro-benchmark harness:

```bash
dart run tool/benchmark_filesystemv.dart
```

Each run writes a JSON result to `tool/benchmark_results/` and prints a
comparison against the previous 3 runs.

Optional flags:

```bash
dart run tool/benchmark_filesystemv.dart --entries=50000 --reads=100000 --writes=25000
```

## Current Holes and Limitations

- This is an `IOOverrides` write overlay, not a security sandbox for untrusted
  code or processes. Keep the store exclusively controlled during the callback.
  Path checks cannot prevent another process or a pre-existing native handle
  from replacing a checked path with a symlink before a subsequent operation.
- Nonempty custom stores are rejected before entering the overlay, including
  stores containing symbolic links or hardlinks. Mapped logical paths and direct store
  paths are checked again when handles or metadata are requested. Existing host
  symlinks may be read when materializing a regular overlay file; writes use
  the checked store path.
- Dart `File`/`Directory`/`Link` objects created before entering `withVFileSystem`
  are not retroactively virtualized. Use ordinary constructors inside the zone.
  The `File.fromRawPath`, `Directory.fromRawPath`, and `Link.fromRawPath`
  constructors bypass `IOOverrides`, even inside the callback, and are outside
  the overlay's protection.
- Spawned native processes bypass Dart `IOOverrides` unless they are directed to
  the overlay path explicitly (for example by using `virtualRoot` as CWD and
  relative paths).
- Directory materialization creates the overlay directory on demand; it does
  not recursively copy host directory contents.
- Path mapping for unusual platform-specific forms (for example complex Windows
  UNC variations) is not fully hardened yet.

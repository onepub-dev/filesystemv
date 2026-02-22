# filesystemv

`filesystemv` provides a write-overlay virtual filesystem for Dart. Reads come
from the host filesystem, while writes are redirected into a virtual store.

This is useful for tests and dry-run workflows where code should behave as if
it writes to disk, without mutating the real machine state.

## Sponsored by OnePub

![OnePub](images/onepub-logo.svg)

Help support DCli by supporting [OnePub](https://onepub.dev), the private dart
repository. OnePub allows you to privately share dart packages between your own
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
  directory is created and cleaned up automatically.
- Return value: the overlay store path.

## Installation

```yaml
dependencies:
  filesystemv: ^0.1.0
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

### 4. Spawn a process using the virtual store as CWD

```dart
import 'dart:io';
import 'package:filesystemv/filesystemv.dart';

Future<void> main() async {
  await withVFileSystem((virtualRoot) async {
    'process.txt'.write('hello world');
    // bash will only see files in the virtualRoot that have been modified 
    await Process.run(
      'bash',
      ['-lc', 'pwd && echo "hello again" >> process.txt && cat process.txt'],
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
}
```

### 6. Link operations

```dart
import 'dart:io';
import 'package:filesystemv/filesystemv.dart';

Future<void> main() async {
  final target = File('/tmp/target.txt')..writeAsStringSync('host');
  final link = Link('/tmp/target-link')..createSync(target.path);

  await withVFileSystem((_) {
    Link(link.path).updateSync('/tmp/another-target.txt');
  }, paths: [link.path]);

  // host link remains unchanged
  print(Link(link.path).targetSync() == target.path);
}
```

## Additional Use Cases

- Protecting host state in integration tests that call third-party libraries.
- Running migration tools in dry-run mode while preserving real data.
- Safe experimentation with config rewrites in CI smoke tests.
- Testing symlink and path handling logic without mutating real links.
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

- Dart `File`/`Directory`/`Link` objects created before entering `withVFileSystem`
  are not retroactively virtualized. Create new handles inside the zone.
- Spawned native processes bypass Dart `IOOverrides` unless they are directed to
  the overlay path explicitly (for example by using `virtualRoot` as CWD and
  relative paths).
- Directory materialization currently copies recursively (directories not files )
  when needed, which may be expensive for large trees .
- Path mapping for unusual platform-specific forms (for example complex Windows
  UNC variations) is not fully hardened yet.

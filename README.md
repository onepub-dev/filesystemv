# filesystemv
A virtual file system that allows you to overload a real filesystem with the virtual file system allowing reads from the overloaded file system but writes are virtualized.

FileSystemV allows your Dart application to read from the underlying real file system but redirects writes to a temporary area.

When the virtual file system shutsdown any writes are lost and the underlying file system remains intact as it was before the virtual file system was created.

FileSystemV is well suited to running unit tests that need access to the host file system but you want to avoid the unit tests making any changes.

FileSystemV use io.Overrides to intercept any write attempts to the file system.

NOTE: any spawned processes or native calls will bypass the virtual file system and write directly to the host file system.

FileSystemV allows you to virtualise the entire host file system or just specific directories:

Virtualise the entire file system.
```dart
import 'package:dcli/dcli.dart';
void main() {
  withVFileSystem(() {
    var pathToEtcHost = '/etc/hosts';
    pathToEtcHost.append(*172.0.0.1 mytesthost');
});
```

Virtualise specific directories:

```dart
import 'package:dcli/dcli.dart';
void main() {
  withVFileSystem(() {
    var pathToEtcHost = '/etc/hosts';
    pathToEtcHost.append(*172.0.0.1 mytesthost');
},
paths: [
'/etc/hosts',
r'$HOME/.pub_cache'
]);
```

Any files/directories that are not virtualised will be written to directly.

If you open a file for writing, the virtual file system will copy the entire file into the virtual file system before the call to open returns - with the obvious performance overhead this imposes.

When you call vFileSystem it creates a temp folder at $TEMP to store any written files.  When the call to `withVFileSystem` returns it will delete that temporary directory.
If you need to control where the files are stored or if you need access to the temporary directory after `withVFileSystem` returns, you can pass in your own path to store the files.


```dart
import 'package:dcli/dcli.dart';
void main() async {
  var pathToSomeFile = '/somefile';
  await withTempDirectoryAsync((tempDir) {
    await withVFileSystem(() {
      var pathToEtcHost = '/etc/hosts';
      pathToEtcHost.append(*172.0.0.1 mytesthost');
      pathToSomeFile.write('Hello World');    
    },
    , store: tempDir);

  // you can now access tempDir
  expect(exists(pathToSomeFile), true);
}
```




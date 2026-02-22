// this is a cli script.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:dcli/dcli.dart';
import 'package:filesystemv/filesystemv.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final hostRoot = createTempDir();
  final hostFile = p.join(hostRoot, 'host.txt')..write('host', newline: '');
  final hostScoped = p.join(hostRoot, 'scoped');
  createDir(hostScoped, recursive: true);
  final hostScopedFile = p.join(hostScoped, 'scoped.txt')
    ..write('scoped', newline: '');
  final hostLink = Link(p.join(hostRoot, 'host-link'))..createSync(hostFile);

  print('Host root: $hostRoot');
  print('Initial host file content: ${read(hostFile)}');

  final overlayPath = await withVFileSystem((virtualRoot) async {
    print('Overlay root: $virtualRoot');

    hostFile.write('virtual-update', newline: '');

    final generated = p.join(hostRoot, 'generated.txt')
      ..write('generated-1', newline: '')
      ..append('generated-2', newline: '');

    // Link update is virtualized.
    Link(hostLink.path).updateSync(hostScopedFile);

    // Spawn process against overlay as working directory.
    final proc = await Process.run(
      'bash',
      ['-lc', 'pwd > cwd.txt && echo process-data > process.txt'],
      workingDirectory: virtualRoot,
    );
    if (proc.exitCode != 0) {
      stderr.writeln(proc.stderr);
    }

    print('Inside overlay file: ${read(hostFile)}');
    print('Inside overlay generated file: ${read(generated)}');
    print('Inside overlay link target: ${Link(hostLink.path).targetSync()}');
  }, paths: [hostRoot]);

  print('withVFileSystem returned overlay path: $overlayPath');
  print('Host file after overlay: ${read(hostFile)}');
  print('Host generated exists: ${exists(p.join(hostRoot, 'generated.txt'))}');
  print('Host link target after overlay: ${Link(hostLink.path).targetSync()}');

  deleteDir(hostRoot);
}

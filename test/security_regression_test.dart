import 'dart:io';

import 'package:filesystemv/filesystemv.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory selected;
  late File host;
  setUp(() {
    root = Directory.systemTemp.createTempSync('filesystemv-security-');
    selected = Directory(p.join(root.path, 'selected'))..createSync();
    host = File(p.join(root.path, 'host'))..writeAsStringSync('untouched');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('logical metadata cache does not alias direct store metadata', () async {
    final first = File(p.join(selected.path, 'first'))
      ..writeAsStringSync('one');
    final second = File(p.join(selected.path, 'second'))
      ..writeAsStringSync('two');
    await withVFileSystem((_) {
      final directory = Directory(selected.path);
      final directFirst = p.join(directory.path, 'first');
      final directSecond = p.join(directory.path, 'second');
      expect(
          FileStat.statSync(directFirst).type, FileSystemEntityType.notFound);
      expect(FileStat.statSync(first.path).type, FileSystemEntityType.file);
      expect(FileStat.statSync(second.path).type, FileSystemEntityType.file);
      expect(
          FileStat.statSync(directSecond).type, FileSystemEntityType.notFound);
      expect(FileStat.statSync(first.path).type, FileSystemEntityType.file);
    });
  });

  for (final asynchronous in [false, true]) {
    test('reopening deleted files preserves absence ($asynchronous)', () async {
      final source = File(p.join(selected.path, 'source'))
        ..writeAsStringSync('host');
      await withVFileSystem((_) async {
        final retained = File(source.path);
        if (asynchronous) {
          await retained.delete();
        } else {
          retained.deleteSync();
        }
        final reopened = File(source.path);
        expect(retained.existsSync(), isFalse);
        expect(reopened.existsSync(), isFalse);
        expect(reopened.statSync().type, FileSystemEntityType.notFound);
        expect(
            FileStat.statSync(source.path).type, FileSystemEntityType.notFound);
        expect(FileSystemEntity.typeSync(source.path),
            FileSystemEntityType.notFound);
        reopened.writeAsStringSync('recreated');
        expect(File(source.path).readAsStringSync(), 'recreated');
        expect(FileStat.statSync(source.path).type, FileSystemEntityType.file);
      });
      expect(source.readAsStringSync(), 'host');
    });

    test('directory deletion hides cached host descendants ($asynchronous)',
        () async {
      final child = File(p.join(selected.path, 'child'))
        ..writeAsStringSync('host');
      final nested = Directory(p.join(selected.path, 'nested'))..createSync();
      final descendant = File(p.join(nested.path, 'descendant'))
        ..writeAsStringSync('host descendant');
      await withVFileSystem((_) async {
        final directory = Directory(selected.path);
        // Merely constructing a directory must preserve lazy host reads.
        expect(FileStat.statSync(child.path).type, FileSystemEntityType.file);
        expect(
            FileStat.statSync(descendant.path).type, FileSystemEntityType.file);
        final retained = File(child.path);
        if (asynchronous) {
          await directory.delete(recursive: true);
        } else {
          directory.deleteSync(recursive: true);
        }
        expect(retained.existsSync(), isFalse);
        expect(Directory(selected.path).existsSync(), isFalse);
        expect(Directory(nested.path).existsSync(), isFalse);
        expect(FileStat.statSync(descendant.path).type,
            FileSystemEntityType.notFound);
        expect(File(child.path).existsSync(), isFalse);
        expect(File(descendant.path).existsSync(), isFalse);
        expect(FileSystemEntity.typeSync(selected.path),
            FileSystemEntityType.notFound);
        Directory(selected.path).createSync();
        expect(File(child.path).existsSync(), isFalse);
        File(child.path).writeAsStringSync('new');
        expect(File(child.path).readAsStringSync(), 'new');
        expect(File(descendant.path).existsSync(), isFalse);
      });
      expect(child.readAsStringSync(), 'host');
      expect(descendant.readAsStringSync(), 'host descendant');
    });
  }

  test('parent traversal reaches a guarded fixed point within a bound',
      () async {
    await withVFileSystem((virtualRoot) {
      var cursor = File(p.join(selected.path, 'child')).parent;
      final maxSteps = p.split(cursor.path).length + 2;
      final seen = <String>{};
      var terminated = false;
      // A synchronous traversal must have a bound: a test timeout cannot
      // interrupt an infinite synchronous loop.
      for (var i = 0; i < maxSteps; i++) {
        expect(seen.add(cursor.path), isTrue, reason: 'parent cycle');
        final parent = cursor.parent;
        if (parent.path == cursor.path) {
          expect(parent.path, virtualRoot);
          expect(() => parent.renameSync(host.path),
              throwsA(isA<FileSystemException>()));
          terminated = true;
          break;
        }
        cursor = parent;
      }
      expect(terminated, isTrue);
    });
  });

  for (final fails in [false, true]) {
    test('nested defaults isolate callbacks and restore outer overlay ($fails)',
        () async {
      String? innerRoot;
      String? outerRoot;
      await withVFileSystem((virtualRoot) async {
        outerRoot = virtualRoot;
        File(host.path).writeAsStringSync('outer');
        Future<String> runInner() => withVFileSystem((nestedRoot) async {
              innerRoot = nestedRoot;
              expect(nestedRoot, isNot(virtualRoot));
              expect(File(host.path).readAsStringSync(), 'untouched');
              await File(host.path).writeAsString('inner');
              expect(File(host.path).readAsStringSync(), 'inner');
              expect(() => Directory.systemTemp.createTempSync(),
                  throwsA(isA<FileSystemException>()));
              if (fails) {
                throw StateError('inner failure');
              }
            });
        if (fails) {
          await expectLater(runInner(), throwsStateError);
        } else {
          await runInner();
        }
        expect(File(host.path).readAsStringSync(), 'outer');
      });
      expect(innerRoot, isNotNull);
      expect(Directory(innerRoot!).existsSync(), isFalse);
      expect(Directory(outerRoot!).existsSync(), isFalse);
      expect(host.readAsStringSync(), 'untouched');
    });
  }

  test('nonempty custom store rejects persisted hardlinks before callback',
      () async {
    final store = Directory(p.join(root.path, 'store'))..createSync();
    final persisted = p.join(store.path, 'hardlink');
    final result = await Process.run('ln', [host.path, persisted]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(FileSystemEntity.identicalSync(host.path, persisted), isTrue);
    var entered = false;
    await expectLater(
        withVFileSystem((_) {
          entered = true;
        }, store: store.path),
        throwsA(isA<FileSystemException>()));
    expect(entered, isFalse);
    expect(host.readAsStringSync(), 'untouched');
    expect(File(persisted).readAsStringSync(), 'untouched');
  }, skip: Platform.isWindows ? 'POSIX hardlink fixture' : false);

  test('ordinary nonempty custom store is rejected', () async {
    final store = Directory(p.join(root.path, 'store'))..createSync();
    File(p.join(store.path, 'persisted')).writeAsStringSync('data');
    var entered = false;
    await expectLater(
        withVFileSystem((_) {
          entered = true;
        }, store: store.path),
        throwsA(isA<FileSystemException>()));
    expect(entered, isFalse);
  });

  test('derived handles and current directory remain guarded', () async {
    final source = File(p.join(selected.path, 'source'))
      ..writeAsStringSync('source');
    await withVFileSystem((virtualRoot) async {
      final file = File(source.path);
      final derived = <FileSystemEntity>[
        file.absolute,
        file.parent,
        ...file.parent.listSync(),
        ...await file.parent.list().toList(),
        Directory.current,
        Directory.systemTemp,
      ];
      var ancestor = file.parent;
      for (var i = 0; i < p.split(virtualRoot).length + 3; i++) {
        ancestor = ancestor.parent;
        derived.add(ancestor);
      }
      for (final entity in derived) {
        expect(() => entity.renameSync(host.path),
            throwsA(isA<FileSystemException>()));
        await expectLater(
            entity.rename(host.path), throwsA(isA<FileSystemException>()));
        if (entity is File) {
          expect(() => entity.copySync(host.path),
              throwsA(isA<FileSystemException>()));
          await expectLater(
              entity.copy(host.path), throwsA(isA<FileSystemException>()));
        }
      }
      final child = File(p.join(selected.path, 'new', 'child'));
      await child.parent.create(recursive: true);
      await child.writeAsString('virtual');
      expect(child.readAsStringSync(), 'virtual');
      await child.delete();
      expect(child.existsSync(), isFalse);
    });
    expect(host.readAsStringSync(), 'untouched');
    expect(source.readAsStringSync(), 'source');
    expect(Directory(p.join(selected.path, 'new')).existsSync(), isFalse);
  });

  for (final kind in ['safe', 'traversal', 'absolute']) {
    test('createTemp rejects before mutation: $kind', () async {
      final prefix = switch (kind) {
        'safe' => 'safe-',
        'traversal' => '../escaped-',
        _ => p.join(root.path, 'absolute-'),
      };
      await withVFileSystem((_) async {
        final directory = Directory(selected.path);
        final before =
            directory.listSync().map((entity) => entity.path).toList();
        expect(() => directory.createTempSync(prefix),
            throwsA(isA<FileSystemException>()));
        await expectLater(
            directory.createTemp(prefix), throwsA(isA<FileSystemException>()));
        expect(
            directory.listSync().map((entity) => entity.path).toList(), before);
      });
      expect(selected.listSync(), isEmpty);
    });
  }

  for (final asynchronous in [false, true]) {
    test('aliased store rejects links ($asynchronous)', () async {
      final alias = Link(p.join(root.path, 'alias'))..createSync(root.path);
      await withVFileSystem((_) async {
        final retained = File(p.join(selected.path, 'missing'));
        final aliasPath =
            p.join(alias.path, p.relative(retained.path, from: root.path));
        await expectLater(() async {
          final link = Link(aliasPath);
          if (asynchronous) {
            await link.create(host.path);
          } else {
            link.createSync(host.path);
          }
        }, throwsA(isA<FileSystemException>()));
        retained.writeAsStringSync('virtual');
      }, paths: [selected.path], store: p.join(alias.path, 'store'));
      expect(host.readAsStringSync(), 'untouched');
    });

    test('outside link rename rejects before mutation ($asynchronous)',
        () async {
      await withVFileSystem((_) async {
        final retained = File(p.join(selected.path, 'missing'));
        final link = Link(p.join(root.path, 'outside'))..createSync(host.path);
        await expectLater(() async {
          if (asynchronous) {
            await link.rename(retained.path);
          } else {
            link.renameSync(retained.path);
          }
        }, throwsA(isA<FileSystemException>()));
        expect(link.existsSync(), isTrue);
        retained.writeAsStringSync('virtual');
      }, paths: [selected.path]);
      expect(host.readAsStringSync(), 'untouched');
    });

    for (final operation in ['copy', 'rename', 'directory rename']) {
      test('$operation rejects before destination mutation ($asynchronous)',
          () async {
        final source = File(p.join(selected.path, 'source'))
          ..writeAsStringSync('source');
        final destination = operation == 'directory rename'
            ? p.join(root.path, 'new-directory')
            : host.path;
        await withVFileSystem((_) async {
          await expectLater(() async {
            if (operation == 'directory rename') {
              final directory = Directory(selected.path);
              if (asynchronous) {
                await directory.rename(destination);
              } else {
                directory.renameSync(destination);
              }
            } else {
              final file = File(source.path);
              if (operation == 'copy') {
                if (asynchronous) {
                  await file.copy(destination);
                } else {
                  file.copySync(destination);
                }
              } else {
                if (asynchronous) {
                  await file.rename(destination);
                } else {
                  file.renameSync(destination);
                }
              }
            }
          }, throwsA(isA<FileSystemException>()));
        });
        expect(host.readAsStringSync(), 'untouched');
        expect(source.readAsStringSync(), 'source');
        if (operation == 'directory rename') {
          expect(Directory(destination).existsSync(), isFalse);
        }
      });
    }
  }
}

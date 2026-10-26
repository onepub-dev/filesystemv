import 'dart:convert';
import 'dart:io';

import 'package:dcli/dcli.dart';
import 'package:filesystemv/filesystemv.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final throwsFileSystemException = throwsA(isA<FileSystemException>());
  group('withVFileSystem', () {
    late Directory root;
    late Directory scoped;
    late File fileA;
    late File fileB;
    late Link linkA;

    setUp(() {
      root = Directory.systemTemp.createTempSync('filesystemv-test-');
      scoped = Directory(p.join(root.path, 'scoped'))
        ..createSync(recursive: true);
      fileA = File(p.join(root.path, 'a.txt'))..writeAsStringSync('A');
      fileB = File(p.join(scoped.path, 'b.txt'))..writeAsStringSync('B');
      linkA = Link(p.join(root.path, 'a-link'))..createSync(fileA.path);
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('virtualizes all writes when paths are omitted', () async {
      await withVFileSystem((_) {
        final inZoneA = File(fileA.path)..writeAsStringSync('changed');
        final created = File(p.join(root.path, 'new.txt'))
          ..writeAsStringSync('new');
        expect(inZoneA.readAsStringSync(), 'changed');
        expect(created.readAsStringSync(), 'new');
      });

      expect(fileA.readAsStringSync(), 'A');
      expect(File(p.join(root.path, 'new.txt')).existsSync(), isFalse);
    });

    test('virtualizes only selected paths', () async {
      await withVFileSystem((_) {
        File(fileA.path).writeAsStringSync('v');
        File(fileB.path).writeAsStringSync('real');
      }, paths: [fileA.path]);

      expect(fileA.readAsStringSync(), 'A');
      expect(fileB.readAsStringSync(), 'real');
    });

    test('supports async actions', () async {
      await withVFileSystem((_) async {
        final inZoneA = File(fileA.path);
        await inZoneA.writeAsString('async-change');
        expect(await inZoneA.readAsString(), 'async-change');
      });

      expect(fileA.readAsStringSync(), 'A');
    });

    test('reads from real file before first virtual write', () async {
      await withVFileSystem((_) {
        expect(fileA.readAsStringSync(), 'A');
      });
    });

    test('subsequent reads use overlay after first write (same handle)',
        () async {
      await withVFileSystem((_) {
        final inZone = File(fileA.path)..writeAsStringSync('overlay-value');
        expect(inZone.readAsStringSync(), 'overlay-value');
        expect(inZone.readAsStringSync(), isNot('A'));
      });
      expect(fileA.readAsStringSync(), 'A');
    });

    test('subsequent reads use overlay after first write (new handle)',
        () async {
      await withVFileSystem((_) {
        File(fileA.path).writeAsStringSync('overlay-value-2');
        final reopened = File(fileA.path);
        expect(reopened.readAsStringSync(), 'overlay-value-2');
      });
      expect(fileA.readAsStringSync(), 'A');
    });

    test('virtualizes directory creations when path is scoped', () async {
      final scopedDir = p.join(root.path, 'scoped-only');
      final scopedFile = p.join(scopedDir, 'child.txt');
      final outsideFile = p.join(root.path, 'outside.txt');

      await withVFileSystem((_) {
        Directory(scopedDir).createSync(recursive: true);
        File(scopedFile).writeAsStringSync('scoped');
        File(outsideFile).writeAsStringSync('outside');
      }, paths: [scopedDir]);

      expect(File(scopedFile).existsSync(), isFalse);
      expect(File(outsideFile).readAsStringSync(), 'outside');
    });

    test('works with path package generated paths', () async {
      final nested = p.join(root.path, 'x', 'y', 'z.txt');
      await withVFileSystem((_) {
        File(nested).createSync(recursive: true);
        File(nested).writeAsStringSync('from-path');
      });
      expect(File(nested).existsSync(), isFalse);
    });

    test('works with dcli write and append', () async {
      await withVFileSystem((_) {
        fileA.path.write('line-1', newline: '');
        fileA.path.append('line-2', newline: '');
        expect(File(fileA.path).readAsStringSync(), 'line-1line-2');
      });
      expect(fileA.readAsStringSync(), 'A');
    });

    test('rejects virtualized link target and update operations', () async {
      final targetB = fileB.path;
      await withVFileSystem((_) {
        expect(() => Link(linkA.path).targetSync(), throwsFileSystemException);
        expect(() => Link(linkA.path).updateSync(targetB),
            throwsFileSystemException);
      }, paths: [linkA.path]);

      expect(Link(linkA.path).targetSync(), fileA.path);
    });

    test('virtualizes writes through linked path when scoped', () async {
      await withVFileSystem((_) {
        File(linkA.path).writeAsStringSync('via-link');
        expect(File(linkA.path).readAsStringSync(), 'via-link');
      }, paths: [linkA.path]);

      expect(fileA.readAsStringSync(), 'A');
    });

    test('overlay-created file link cannot overwrite a host file', () async {
      final virtualLink = p.join(root.path, 'virtual-link');

      await withVFileSystem((_) {
        expect(
          () => Link(virtualLink).createSync(fileA.path, recursive: true),
          throwsFileSystemException,
        );
        File(virtualLink).writeAsStringSync('isolated');
      });

      expect(fileA.readAsStringSync(), 'A');
    });

    test('overlay-created directory link cannot create a host file', () async {
      final virtualLink = p.join(root.path, 'virtual-dir-link');
      final hostChild = File(p.join(scoped.path, 'escaped.txt'));

      await withVFileSystem((_) {
        expect(
          () => Link(virtualLink).createSync(scoped.path, recursive: true),
          throwsFileSystemException,
        );
        File(p.join(virtualLink, 'escaped.txt')).writeAsStringSync('isolated');
      });

      expect(hostChild.existsSync(), isFalse);
    });

    test('link updates outside scoped paths stay real', () async {
      Link? realLink;
      try {
        realLink = Link(p.join(root.path, 'outside-link'))
          ..createSync(fileA.path);
        await withVFileSystem((_) {
          Link(realLink!.path).updateSync(fileB.path);
        }, paths: [scoped.path]);
        expect(realLink.targetSync(), fileB.path);
      } finally {
        if (realLink != null && realLink.existsSync()) {
          realLink.deleteSync();
        }
      }
    });

    test('rejects async link creation and updates before returning a handle',
        () async {
      await withVFileSystem((_) async {
        await expectLater(
          Future<void>.sync(() async {
            await Link(p.join(root.path, 'async-link')).create(fileA.path);
          }),
          throwsFileSystemException,
        );
        await expectLater(
          Future<void>.sync(() async {
            await Link(linkA.path).update(fileB.path);
          }),
          throwsFileSystemException,
        );
      });
      expect(linkA.targetSync(), fileA.path);
      expect(fileA.readAsStringSync(), 'A');
      expect(fileB.readAsStringSync(), 'B');
    });

    test('rejects direct store links even with selected paths', () async {
      await withVFileSystem((store) {
        for (final target in [fileA.path, '../a.txt', scoped.path]) {
          expect(
            () => Link(p.join(store, 'escape')).createSync(target),
            throwsFileSystemException,
          );
        }
      }, paths: [scoped.path]);
      expect(fileA.readAsStringSync(), 'A');
    });

    for (final location in [
      'file',
      'directory',
      'dangling',
      'relative',
      'index',
      'index-bucket',
    ]) {
      test('rejects persisted $location symlink before entering the overlay',
          () async {
        final store = Directory(p.join(root.path, 'store'))..createSync();
        final mappedFile = p.join(
            store.path, p.relative(fileA.path, from: p.rootPrefix(fileA.path)));
        final String linkPath;
        final String target;
        switch (location) {
          case 'directory':
            linkPath = p.dirname(mappedFile);
            target = root.path;
          case 'dangling':
            linkPath = mappedFile;
            target = p.join(root.path, 'missing-host-file');
          case 'relative':
            linkPath = mappedFile;
            target = p.relative(fileA.path, from: p.dirname(linkPath));
          case 'index':
            linkPath = p.join(store.path, '.filesystemv_shadow_index');
            target = scoped.path;
          case 'index-bucket':
            linkPath = p.join(store.path, '.filesystemv_shadow_index', '0.bin');
            target = fileA.path;
          default:
            linkPath = mappedFile;
            target = fileA.path;
        }
        Directory(p.dirname(linkPath)).createSync(recursive: true);
        Link(linkPath).createSync(target);

        var entered = false;
        await expectLater(
          withVFileSystem((_) {
            entered = true;
            File(fileA.path).writeAsStringSync('escaped');
          }, store: store.path),
          throwsFileSystemException,
        );

        expect(entered, isFalse);
        expect(fileA.readAsStringSync(), 'A');
        expect(
            File(p.join(root.path, 'missing-host-file')).existsSync(), isFalse);
        expect(scoped.listSync().map((entry) => entry.path), [fileB.path]);
      });
    }

    test('rejects a symlink store root including through an aliased parent',
        () async {
      final alias = Link(p.join(root.path, 'store-alias'))
        ..createSync(scoped.path);
      Link(p.join(scoped.path, 'nested-link')).createSync(root.path);
      for (final store in [alias.path, p.join(alias.path, 'nested-link')]) {
        await expectLater(
          withVFileSystem((_) => fail('unsafe store was accepted'),
              store: store),
          throwsFileSystemException,
        );
      }
      expect(Directory(p.join(scoped.path, 'new-store')).existsSync(), isFalse);
      expect(fileB.readAsStringSync(), 'B');
    });

    for (final suffix in ['existing', 'missing/parent/store']) {
      test('canonicalizes aliased store ancestors for $suffix', () async {
        final alias = Link(p.join(root.path, 'parent-alias'))
          ..createSync(scoped.path);
        final requested = p.join(alias.path, suffix);
        if (suffix == 'existing') {
          Directory(requested).createSync();
        }
        final expected = p.join(scoped.resolveSymbolicLinksSync(), suffix);
        final returned = await withVFileSystem((virtualRoot) {
          expect(virtualRoot, expected);
          File(fileA.path).writeAsStringSync('overlay');
          expect(File(fileA.path).readAsStringSync(), 'overlay');
          expect(() => Link(p.join(virtualRoot, 'escape')),
              throwsFileSystemException);
        }, store: requested);
        expect(returned, expected);
        expect(Directory(returned).existsSync(), isTrue);
        expect(fileA.readAsStringSync(), 'A');
      });
    }

    test('rejects persisted symlinks beneath an aliased store parent',
        () async {
      final alias = Link(p.join(root.path, 'parent-alias'))
        ..createSync(scoped.path);
      final store = Directory(p.join(scoped.path, 'store'))..createSync();
      Link(p.join(store.path, 'escape')).createSync(fileA.path);
      await expectLater(
        withVFileSystem((_) => fail('unsafe store was accepted'),
            store: p.join(alias.path, 'store')),
        throwsFileSystemException,
      );
      expect(fileA.readAsStringSync(), 'A');
      expect(
          Directory(p.join(store.path, '.filesystemv_shadow_index'))
              .existsSync(),
          isFalse);
    });

    test('default temp store is canonical and cleaned up', () async {
      late String canonicalRoot;
      final returned = await withVFileSystem((virtualRoot) {
        canonicalRoot = Directory(virtualRoot).resolveSymbolicLinksSync();
        expect(virtualRoot, canonicalRoot);
        File(fileA.path).writeAsStringSync('overlay');
      });
      expect(returned, canonicalRoot);
      expect(Directory(returned).existsSync(), isFalse);
      expect(fileA.readAsStringSync(), 'A');
    });

    test('rechecks store paths for files directories and cached metadata',
        () async {
      final store = Directory(p.join(root.path, 'store'))..createSync();
      final mappedParent = Directory(p.join(store.resolveSymbolicLinksSync(),
          p.relative(root.path, from: p.rootPrefix(root.path))));
      final injectedLink = Link(mappedParent.path);
      await withVFileSystem((virtualRoot) {
        File(fileA.path);
        expect(
            FileSystemEntity.typeSync(fileA.path), FileSystemEntityType.file);
        // Pre-zone handles simulate a store changed by an external writer.
        mappedParent.deleteSync(recursive: true);
        injectedLink.createSync(root.path);

        expect(() => File(fileA.path), throwsFileSystemException);
        expect(() => Directory(root.path), throwsFileSystemException);
        expect(() => FileSystemEntity.typeSync(fileA.path),
            throwsFileSystemException);
        expect(() => File(p.join(mappedParent.path, 'a.txt')),
            throwsFileSystemException);
        expect(() => Directory(mappedParent.path), throwsFileSystemException);
      }, store: store.path);
      expect(fileA.readAsStringSync(), 'A');
    });

    test('keeps overlay store when custom store is provided', () async {
      final store = Directory.systemTemp.createTempSync('filesystemv-store-');
      try {
        await withVFileSystem((_) {
          File(fileA.path).writeAsStringSync('overlay');
        }, store: store.path);

        final overlayFile = File(
            p.join(store.path, p.normalize(fileA.absolute.path).substring(1)));
        expect(overlayFile.existsSync(), isTrue);
        expect(overlayFile.readAsStringSync(), 'overlay');
      } finally {
        if (store.existsSync()) {
          store.deleteSync(recursive: true);
        }
      }
    });

    test('supports dcli exists checks inside virtualization', () async {
      await withVFileSystem((_) {
        final pathToCreated = p.join(root.path, 'exists.txt')
          ..write('ok', newline: '');
        expect(exists(pathToCreated), isTrue);
      });
      expect(exists(p.join(root.path, 'exists.txt')), isFalse);
    });

    test('returns virtual root path to callback and caller', () async {
      final returned = await withVFileSystem((virtualRoot) {
        expect(Directory(virtualRoot).existsSync(), isTrue);
        File(p.join(virtualRoot, 'cwd-marker.txt')).writeAsStringSync('ok');
      });

      expect(returned, isA<String>());
      expect(returned, isNotEmpty);
      expect(Directory(returned).existsSync(), isFalse);
    });

    test('supports File.openSync and RandomAccessFile operations', () async {
      final hostBefore = fileA.readAsStringSync();

      await withVFileSystem((_) {
        File(fileA.path).openSync(mode: FileMode.writeOnlyAppend)
          ..writeStringSync('-tail')
          ..flushSync()
          ..closeSync();

        final reader = File(fileA.path).openSync();
        final bytes = reader.readSync(reader.lengthSync());
        expect(utf8.decode(bytes), 'A-tail');
        reader.closeSync();
      });

      expect(fileA.readAsStringSync(), hostBefore);
    });

    test('supports async File.open and RandomAccessFile operations', () async {
      final hostBefore = fileA.readAsStringSync();

      await withVFileSystem((_) async {
        final raf = await File(fileA.path).open(mode: FileMode.write);
        await raf.writeString('replaced');
        await raf.setPosition(0);
        final readBack = utf8.decode(await raf.read(8));
        await raf.close();
        expect(readBack, 'replaced');
      });

      expect(fileA.readAsStringSync(), hostBefore);
    });

    test('supports openWrite and openRead stream APIs', () async {
      final streamPath = p.join(root.path, 'stream.txt');

      await withVFileSystem((_) async {
        final sink = File(streamPath).openWrite()
          ..write('alpha')
          ..write('beta');
        await sink.flush();
        await sink.close();

        final content = await File(streamPath)
            .openRead()
            .transform(const SystemEncoding().decoder)
            .join();
        expect(content, 'alphabeta');
      });

      expect(File(streamPath).existsSync(), isFalse);
      expect(fileA.readAsStringSync(), 'A');
      expect(fileB.readAsStringSync(), 'B');
    });

    test('rejects rename and copy but supports delete without mutating host',
        () async {
      final hostBefore = fileA.readAsStringSync();
      final renamed = p.join(root.path, 'renamed.txt');
      final copied = p.join(root.path, 'copied.txt');

      await withVFileSystem((_) {
        final source = File(fileA.path);
        final copiedFile = File(copied);
        expect(
            () => source.copySync(copiedFile.path), throwsFileSystemException);
        expect(copiedFile.existsSync(), isFalse);

        final renamedFile = File(renamed);
        expect(() => source.renameSync(renamedFile.path),
            throwsFileSystemException);
        expect(renamedFile.existsSync(), isFalse);
        expect(source.existsSync(), isTrue);

        source.deleteSync();
        expect(source.existsSync(), isFalse);
      });

      expect(fileA.readAsStringSync(), hostBefore);
      expect(File(renamed).existsSync(), isFalse);
      expect(File(copied).existsSync(), isFalse);
    });

    test('supports stat type and identical APIs in zone', () async {
      await withVFileSystem((_) {
        File(fileA.path).writeAsStringSync('zone');

        final stat = FileStat.statSync(fileA.path);
        expect(stat.type, FileSystemEntityType.file);

        final type = FileSystemEntity.typeSync(fileA.path);
        expect(type, FileSystemEntityType.file);

        expect(FileSystemEntity.identicalSync(fileA.path, fileA.path), isTrue);
      });

      expect(fileA.readAsStringSync(), 'A');
    });

    test('keeps host link target unchanged after virtual link operations',
        () async {
      final hostTarget = Link(linkA.path).targetSync();

      await withVFileSystem((_) {
        expect(() => Link(linkA.path).updateSync(fileB.path),
            throwsFileSystemException);
      });

      expect(Link(linkA.path).targetSync(), hostTarget);
      expect(fileA.readAsStringSync(), 'A');
      expect(fileB.readAsStringSync(), 'B');
    });

    test('supports async stat type and identical APIs', () async {
      await withVFileSystem((_) async {
        File(fileA.path).writeAsStringSync('zone-async');

        final stat = await FileStat.stat(fileA.path);
        expect(stat.type, FileSystemEntityType.file);
        expect(stat.size, 10);
        // we are specically testing the async stat here.
        // ignore: avoid_slow_async_io
        final type = await FileSystemEntity.type(fileA.path);
        expect(type, FileSystemEntityType.file);

        final same = await FileSystemEntity.identical(fileA.path, fileA.path);
        expect(same, isTrue);
      });

      expect(fileA.readAsStringSync(), 'A');
    });

    test('delete in zone does not mutate host and remains absent in-zone',
        () async {
      final hostBefore = fileA.readAsStringSync();
      await withVFileSystem((_) {
        final inZone = File(fileA.path)..deleteSync();
        expect(inZone.existsSync(), isFalse);
        expect(FileSystemEntity.typeSync(fileA.path),
            FileSystemEntityType.notFound);
      });

      expect(fileA.readAsStringSync(), hostBefore);
      expect(fileA.existsSync(), isTrue);
    });

    test('scoped path matching does not virtualize sibling prefix paths',
        () async {
      final scopedRoot = p.join(root.path, 'scope');
      final scopedChild = p.join(scopedRoot, 'child.txt');
      final siblingPrefix = p.join(root.path, 'scope2.txt');

      Directory(scopedRoot).createSync(recursive: true);

      await withVFileSystem((_) {
        File(scopedChild).writeAsStringSync('virtual');
        File(siblingPrefix).writeAsStringSync('real');
      }, paths: [scopedRoot]);

      expect(File(scopedChild).existsSync(), isFalse);
      expect(File(siblingPrefix).readAsStringSync(), 'real');
    });

    test('relative paths honor Directory.current inside zone', () async {
      final hostCwd = Directory.current.path;
      final tempCwd = Directory(p.join(root.path, 'cwd'))
        ..createSync(recursive: true);

      Directory.current = tempCwd.path;
      try {
        await withVFileSystem((_) {
          expect(() => Directory.current = tempCwd.path,
              throwsFileSystemException);
          File('relative.txt').writeAsStringSync('virtual-relative');
          expect(File('relative.txt').readAsStringSync(), 'virtual-relative');
          expect(
              File(p.join(tempCwd.path, 'relative.txt')).existsSync(), isTrue);
        }, paths: [tempCwd.path]);
      } finally {
        Directory.current = hostCwd;
      }
      expect(File(p.join(tempCwd.path, 'relative.txt')).existsSync(), isFalse);
    });

    test('reports fs watch support consistently in-zone', () async {
      final hostSupport = FileSystemEntity.isWatchSupported;
      await withVFileSystem((_) {
        expect(FileSystemEntity.isWatchSupported, hostSupport);
      });
    });

    test('emits watch events for virtualized directory writes', () async {
      if (!FileSystemEntity.isWatchSupported) {
        return;
      }

      final watchedDirPath = p.join(root.path, 'watched');
      Directory(watchedDirPath).createSync(recursive: true);

      await withVFileSystem((_) async {
        final watchedDir = Directory(watchedDirPath);
        final firstEvent =
            watchedDir.watch().first.timeout(const Duration(seconds: 3));

        File(p.join(watchedDirPath, 'new.txt')).writeAsStringSync('watch-me');

        final event = await firstEvent;
        expect(event.path, contains('new.txt'));
      }, paths: [watchedDirPath]);

      expect(File(p.join(watchedDirPath, 'new.txt')).existsSync(), isFalse);
    });
  });
}

// Async wrappers intentionally capture validation failures as Future errors.
// ignore_for_file: unnecessary_async, avoid_slow_async_io

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'overlay_overrides.dart';

/// Native delegates stay private; every derived entity re-enters the overlay.
abstract class _GuardedEntity<T extends FileSystemEntity>
    implements FileSystemEntity {
  _GuardedEntity(this.overlay, T native) : _native = native;

  final OverlayOverrides overlay;
  final T _native;
  T get _delegate {
    overlay.validateHandlePath(_native.path);
    return _native;
  }

  T _wrap(String path);

  Never _unsupported(String operation) => throw FileSystemException(
        '$operation is not supported by overlay handles',
        path,
      );

  @override
  String get path => _native.path;
  @override
  Uri get uri => _native.uri;
  @override
  bool get isAbsolute => _native.isAbsolute;
  @override
  T get absolute => _wrap(_native.absolute.path);
  @override
  Directory get parent => overlay.parentOf(path);
  @override
  Future<bool> exists() async => _delegate.exists();
  @override
  bool existsSync() => _delegate.existsSync();
  @override
  Future<T> rename(String newPath) async => _unsupported('rename');
  @override
  T renameSync(String newPath) => _unsupported('rename');
  @override
  Future<String> resolveSymbolicLinks() async =>
      _delegate.resolveSymbolicLinks();
  @override
  String resolveSymbolicLinksSync() => _delegate.resolveSymbolicLinksSync();
  @override
  Future<FileStat> stat() async => _delegate.stat();
  @override
  FileStat statSync() => _delegate.statSync();
  @override
  Future<T> delete({bool recursive = false}) async {
    await _delegate.delete(recursive: recursive);
    overlay.didDelete(path);
    return this as T;
  }

  @override
  void deleteSync({bool recursive = false}) {
    _delegate.deleteSync(recursive: recursive);
    overlay.didDelete(path);
  }

  @override
  Stream<FileSystemEvent> watch(
          {int events = FileSystemEvent.all, bool recursive = false}) =>
      _delegate.watch(events: events, recursive: recursive);
}

final class GuardedFile extends _GuardedEntity<File> implements File {
  GuardedFile(super.overlay, super.native);
  @override
  File _wrap(String path) => overlay.createFile(path);
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    await _delegate.create(recursive: recursive, exclusive: exclusive);
    return this;
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      _delegate.createSync(recursive: recursive, exclusive: exclusive);
  @override
  Future<File> copy(String newPath) async => _unsupported('copy');
  @override
  File copySync(String newPath) => _unsupported('copy');
  @override
  Future<int> length() async => _delegate.length();
  @override
  int lengthSync() => _delegate.lengthSync();
  @override
  Future<DateTime> lastAccessed() async => _delegate.lastAccessed();
  @override
  DateTime lastAccessedSync() => _delegate.lastAccessedSync();
  @override
  Future<void> setLastAccessed(DateTime time) async =>
      _delegate.setLastAccessed(time);
  @override
  void setLastAccessedSync(DateTime time) =>
      _delegate.setLastAccessedSync(time);
  @override
  Future<DateTime> lastModified() async => _delegate.lastModified();
  @override
  DateTime lastModifiedSync() => _delegate.lastModifiedSync();
  @override
  Future<void> setLastModified(DateTime time) async =>
      _delegate.setLastModified(time);
  @override
  void setLastModifiedSync(DateTime time) =>
      _delegate.setLastModifiedSync(time);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _delegate.open(mode: mode);
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _delegate.openSync(mode: mode);
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      _delegate.openRead(start, end);
  @override
  IOSink openWrite(
          {FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      _delegate.openWrite(mode: mode, encoding: encoding);
  @override
  Future<Uint8List> readAsBytes() async => _delegate.readAsBytes();
  @override
  Uint8List readAsBytesSync() => _delegate.readAsBytesSync();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      _delegate.readAsString(encoding: encoding);
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      _delegate.readAsStringSync(encoding: encoding);
  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) async =>
      _delegate.readAsLines(encoding: encoding);
  @override
  List<String> readAsLinesSync({Encoding encoding = utf8}) =>
      _delegate.readAsLinesSync(encoding: encoding);
  @override
  Future<File> writeAsBytes(List<int> bytes,
      {FileMode mode = FileMode.write, bool flush = false}) async {
    await _delegate.writeAsBytes(bytes, mode: mode, flush: flush);
    return this;
  }

  @override
  void writeAsBytesSync(List<int> bytes,
          {FileMode mode = FileMode.write, bool flush = false}) =>
      _delegate.writeAsBytesSync(bytes, mode: mode, flush: flush);
  @override
  Future<File> writeAsString(String contents,
      {FileMode mode = FileMode.write,
      Encoding encoding = utf8,
      bool flush = false}) async {
    await _delegate.writeAsString(contents,
        mode: mode, encoding: encoding, flush: flush);
    return this;
  }

  @override
  void writeAsStringSync(String contents,
          {FileMode mode = FileMode.write,
          Encoding encoding = utf8,
          bool flush = false}) =>
      _delegate.writeAsStringSync(contents,
          mode: mode, encoding: encoding, flush: flush);
}

final class GuardedDirectory extends _GuardedEntity<Directory>
    implements Directory {
  GuardedDirectory(super.overlay, super.native);
  @override
  Directory _wrap(String path) => overlay.createDirectory(path);
  @override
  Future<Directory> create({bool recursive = false}) async {
    await _delegate.create(recursive: recursive);
    return this;
  }

  @override
  void createSync({bool recursive = false}) =>
      _delegate.createSync(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _unsupported('createTemp');
  @override
  Directory createTempSync([String? prefix]) => _unsupported('createTemp');
  FileSystemEntity _wrapEntity(FileSystemEntity entity) {
    if (entity is File) {
      return overlay.createFile(entity.path);
    }
    if (entity is Directory) {
      return overlay.createDirectory(entity.path);
    }
    if (entity is Link) {
      return overlay.createLink(entity.path);
    }
    throw FileSystemException('Unsupported entity type', entity.path);
  }

  @override
  Stream<FileSystemEntity> list(
          {bool recursive = false, bool followLinks = true}) =>
      _delegate
          .list(recursive: recursive, followLinks: followLinks)
          .map(_wrapEntity);
  @override
  List<FileSystemEntity> listSync(
          {bool recursive = false, bool followLinks = true}) =>
      _delegate
          .listSync(recursive: recursive, followLinks: followLinks)
          .map(_wrapEntity)
          .toList();
}

final class GuardedLink extends _GuardedEntity<Link> implements Link {
  GuardedLink(super.overlay, super.native);
  @override
  Link _wrap(String path) => overlay.createLink(path);
  @override
  Future<Link> create(String target, {bool recursive = false}) async {
    await _delegate.create(target, recursive: recursive);
    return this;
  }

  @override
  void createSync(String target, {bool recursive = false}) =>
      _delegate.createSync(target, recursive: recursive);
  @override
  Future<Link> update(String target) async {
    await _delegate.update(target);
    return this;
  }

  @override
  void updateSync(String target) => _delegate.updateSync(target);
  @override
  Future<String> target() async => _delegate.target();
  @override
  String targetSync() => _delegate.targetSync();
}

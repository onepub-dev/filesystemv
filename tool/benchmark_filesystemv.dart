#!/usr/bin/env dcli

import 'dart:convert';
import 'dart:io';

import 'package:filesystemv/filesystemv.dart';
import 'package:filesystemv/src/resolved_path_cache.dart';
import 'package:filesystemv/src/shadowed_path_index.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final config = _BenchmarkConfig.fromArgs(args);
  final previousRuns = _loadPreviousRuns(limit: 3);

  final lines = <String>['filesystemv benchmark', config.toSummary()];

  final resolved = _benchResolvedPathCache(config);
  final shadowed = _benchShadowedPathIndex(config);
  final overlay = await _benchWithVFileSystem(config);

  final run = _BenchmarkRun(
    timestampUtc: DateTime.now().toUtc(),
    config: config,
    metrics: <String, num>{
      ...resolved.metrics,
      ...shadowed.metrics,
      ...overlay.metrics,
    },
  );

  final outputFile = _writeRun(run);
  lines
    ..add('wrote result: ${outputFile.path}')
    ..add(resolved.summary)
    ..add(shadowed.summary)
    ..add(overlay.summary)
    ..addAll(_compareToHistory(run, previousRuns));

  for (final line in lines) {
    stdout.writeln(line);
  }
}

_BenchmarkSection _benchResolvedPathCache(_BenchmarkConfig c) {
  final cache = ResolvedPathCache(maxEntries: c.entries);
  final sw = Stopwatch()..start();

  for (var i = 0; i < c.entries; i++) {
    cache.put('/root/$i/file.txt', '/v/root/$i/file.txt');
  }
  for (var i = 0; i < c.reads; i++) {
    cache.get('/root/${i % c.entries}/file.txt');
  }
  for (var i = 0; i < c.writes; i++) {
    cache
      ..invalidate('/root/${i % c.entries}')
      ..put('/root/${i % c.entries}/file.txt', '/v/new/$i');
  }
  sw.stop();

  return _BenchmarkSection(
    summary: '''
ResolvedPathCache: ${sw.elapsedMilliseconds}ms (entryCount=${cache.entryCount})''',
    metrics: <String, num>{
      'resolved_ms': sw.elapsedMilliseconds,
      'resolved_entry_count': cache.entryCount,
    },
  );
}

_BenchmarkSection _benchShadowedPathIndex(_BenchmarkConfig c) {
  final temp = Directory.systemTemp.createTempSync('fsv-bench-index-');
  try {
    final index = ShadowedPathIndex(
      storageRoot: temp.path,
      maxInMemoryEntries: c.entries ~/ 8,
    );
    final sw = Stopwatch()..start();

    for (var i = 0; i < c.entries; i++) {
      index.add('/bench/path/$i');
    }
    for (var i = 0; i < c.reads; i++) {
      index.containsExact('/bench/path/${i % c.entries}');
    }
    for (var i = 0; i < c.reads; i++) {
      index.containsExact('/bench/missing/$i');
    }
    sw.stop();

    return _BenchmarkSection(
      summary: 'ShadowedPathIndex: ${sw.elapsedMilliseconds}ms '
          '(inMemory=${index.inMemoryCount} spilled=${index.spilledEntryCount} '
          'diskScans=${index.debugDiskScanCount} '
          'offsetLoads=${index.debugOffsetIndexLoadCount})',
      metrics: <String, num>{
        'shadowed_ms': sw.elapsedMilliseconds,
        'shadowed_in_memory': index.inMemoryCount,
        'shadowed_spilled': index.spilledEntryCount,
        'shadowed_disk_scans': index.debugDiskScanCount,
        'shadowed_offset_loads': index.debugOffsetIndexLoadCount,
      },
    );
  } finally {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  }
}

Future<_BenchmarkSection> _benchWithVFileSystem(_BenchmarkConfig c) async {
  final temp = Directory.systemTemp.createTempSync('fsv-bench-overlay-');
  try {
    for (var i = 0; i < c.entries; i++) {
      File(p.join(temp.path, 'seed-$i.txt')).writeAsStringSync('seed-$i');
    }

    final sw = Stopwatch()..start();
    await withVFileSystem((_) {
      for (var i = 0; i < c.writes; i++) {
        File(p.join(temp.path, 'seed-${i % c.entries}.txt'))
            .writeAsStringSync('overlay-$i');
      }
      for (var i = 0; i < c.reads; i++) {
        File(p.join(temp.path, 'seed-${i % c.entries}.txt')).readAsStringSync();
      }
    });
    sw.stop();

    return _BenchmarkSection(
      summary: 'withVFileSystem (sync body): ${sw.elapsedMilliseconds}ms',
      metrics: <String, num>{'overlay_ms': sw.elapsedMilliseconds},
    );
  } finally {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  }
}

List<String> _compareToHistory(
    _BenchmarkRun current, List<_BenchmarkRun> prior) {
  if (prior.isEmpty) {
    return <String>['history: no previous runs'];
  }
  final lines = <String>[
    'history: comparing with ${prior.length} previous runs'
  ];
  for (final run in prior) {
    final sameConfig = current.config.matches(run.config);
    lines
      ..add(
        '  run ${run.timestampUtc.toIso8601String()} '
        '${sameConfig ? '' : '(config differs)'}',
      )
      ..add(
        '''
    resolved_ms: ${_deltaLine(current.metric('resolved_ms'), run.metric('resolved_ms'))}''',
      )
      ..add(
        '''
    shadowed_ms: ${_deltaLine(current.metric('shadowed_ms'), run.metric('shadowed_ms'))}''',
      )
      ..add(
        '''
    overlay_ms:  ${_deltaLine(current.metric('overlay_ms'), run.metric('overlay_ms'))}''',
      );
  }
  return lines;
}

String _deltaLine(num current, num previous) {
  final delta = current - previous;
  final pct = previous == 0 ? 0 : (delta / previous) * 100.0;
  final sign = delta >= 0 ? '+' : '';
  return '$current vs $previous ($sign${delta.toStringAsFixed(1)}, '
      '$sign${pct.toStringAsFixed(2)}%)';
}

File _writeRun(_BenchmarkRun run) {
  final outputDir = Directory(p.join('tool', 'benchmark_results'))
    ..createSync(recursive: true);
  final stamp = run.timestampUtc
      .toIso8601String()
      .replaceAll(':', '-')
      .replaceAll('.', '-');
  final file = File(p.join(outputDir.path, '$stamp.json'))
    ..writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(run.toJson()),
    );
  return file;
}

List<_BenchmarkRun> _loadPreviousRuns({required int limit}) {
  final outputDir = Directory(p.join('tool', 'benchmark_results'));
  if (!outputDir.existsSync()) {
    return <_BenchmarkRun>[];
  }
  final files = outputDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    return <_BenchmarkRun>[];
  }
  final start = files.length - limit < 0 ? 0 : files.length - limit;
  final selected = files.sublist(start);
  return selected.map(_readRun).toList();
}

_BenchmarkRun _readRun(File file) {
  final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return _BenchmarkRun.fromJson(map);
}

final class _BenchmarkSection {
  _BenchmarkSection({required this.summary, required this.metrics});

  final String summary;
  final Map<String, num> metrics;
}

final class _BenchmarkConfig {
  _BenchmarkConfig({
    required this.entries,
    required this.reads,
    required this.writes,
  });

  final int entries;
  final int reads;
  final int writes;

  String toSummary() => 'entries=$entries reads=$reads writes=$writes';

  Map<String, Object?> toJson() => <String, Object?>{
        'entries': entries,
        'reads': reads,
        'writes': writes,
      };

  factory _BenchmarkConfig.fromJson(Map<String, dynamic> json) =>
      _BenchmarkConfig(
        entries: json['entries'] as int,
        reads: json['reads'] as int,
        writes: json['writes'] as int,
      );

  factory _BenchmarkConfig.fromArgs(List<String> args) {
    var entries = 20000;
    var reads = 40000;
    var writes = 10000;
    for (final arg in args) {
      if (arg.startsWith('--entries=')) {
        entries = int.parse(arg.substring('--entries='.length));
      } else if (arg.startsWith('--reads=')) {
        reads = int.parse(arg.substring('--reads='.length));
      } else if (arg.startsWith('--writes=')) {
        writes = int.parse(arg.substring('--writes='.length));
      }
    }
    return _BenchmarkConfig(entries: entries, reads: reads, writes: writes);
  }

  bool matches(_BenchmarkConfig other) =>
      entries == other.entries &&
      reads == other.reads &&
      writes == other.writes;
}

final class _BenchmarkRun {
  _BenchmarkRun({
    required this.timestampUtc,
    required this.config,
    required this.metrics,
  });

  final DateTime timestampUtc;
  final _BenchmarkConfig config;
  final Map<String, num> metrics;

  num metric(String key) => metrics[key] ?? 0;

  Map<String, Object?> toJson() => <String, Object?>{
        'timestampUtc': timestampUtc.toIso8601String(),
        'config': config.toJson(),
        'metrics': metrics.map(
          MapEntry<String, Object?>.new,
        ),
      };

  factory _BenchmarkRun.fromJson(Map<String, dynamic> json) => _BenchmarkRun(
        timestampUtc: DateTime.parse(json['timestampUtc'] as String),
        config:
            _BenchmarkConfig.fromJson(json['config'] as Map<String, dynamic>),
        metrics: (json['metrics'] as Map<String, dynamic>).map(
          (key, value) => MapEntry<String, num>(key, value as num),
        ),
      );
}

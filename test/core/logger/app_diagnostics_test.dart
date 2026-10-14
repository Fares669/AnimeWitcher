import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/logger/app_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AppDiagnostics log;
  var now = DateTime.utc(2026, 10, 14);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('app-diagnostics-test-');
    now = DateTime.utc(2026, 10, 14);
    log = AppDiagnostics(
      directoryProvider: () async => Directory('${root.path}/logs'),
      exportDirectoryProvider: () async => Directory('${root.path}/exports'),
      now: () => now,
    );
  });

  tearDown(() async {
    await log.setEnabled(false);
    await log.flush();
    await root.delete(recursive: true);
  });

  Future<List<Map<String, Object?>>> rows() async {
    final file = await log.export();
    return (await file.readAsLines())
        .where((line) => line.isNotEmpty)
        .map((line) => (jsonDecode(line) as Map).cast<String, Object?>())
        .toList();
  }

  test(
    'starts disabled and disabling preserves ordered captured events',
    () async {
      log.record('startup_phase', fields: {'phase': 'app_ready'});
      expect(log.enabled, isFalse);
      expect(await log.listFiles(), isEmpty);
      await log.setEnabled(true);
      log.record('startup_phase', fields: {'phase': 'app_ready'});
      log.record('navigation', fields: {'route': 'home'});
      await log.setEnabled(false);
      log.record('navigation', fields: {'route': 'search'});
      final data = await rows();
      expect(data.map((row) => row['event']), [
        'logging.enabled',
        'startup_phase',
        'navigation',
        'logging.disabled',
      ]);
      expect(data.map((row) => row['sequence']), [1, 2, 3, 4]);
      expect(log.enabled, isFalse);
    },
  );

  test(
    'rejects secret event strings, fields, values, and nonfinite numbers',
    () async {
      await log.setEnabled(true);
      log.record('private_secret');
      log.record('https://private_secret.example/api?token=private_secret');
      log.record(
        'network_finish',
        fields: {
          'url': 'https://private_secret.example/api',
          'headers': {'Authorization': 'Bearer private_secret'},
          'title': 'private_secret',
          'path': '/Users/private_secret/file',
          'userId': 'private_secret',
          'requestId': 'private_secret',
          'status': 'private_secret',
          'reason': 'private_secret',
          'elapsedMs': double.nan,
          'bytes': double.infinity,
          'method': 'GET',
          'duration_ms': 12,
          'request_id': 7,
        },
      );
      final file = await log.export();
      final content = await file.readAsString();
      expect(content, isNot(contains('private_secret')));
      final row = (await rows()).last;
      expect(row['method'], 'GET');
      expect(row['duration_ms'], 12);
      expect(row['request_id'], 7);
      expect(row.containsKey('elapsedMs'), isFalse);
      expect(row.containsKey('bytes'), isFalse);
    },
  );

  test(
    'records fixed playback preflight phases without identity or path data',
    () async {
      await log.setEnabled(true);
      log.record(
        'playback.launch',
        fields: {'requestId': 1, 'phase': 'begin', 'local': true},
      );
      for (final operation in [
        'fileResolve',
        'playerSettings',
        'historyOpen',
        'routePush',
      ]) {
        log.record(
          'playback.phase',
          fields: {
            'requestId': 1,
            'operation': operation,
            'phase': 'begin',
            'url': 'private_secret',
            'path': 'private_secret',
            'title': 'private_secret',
          },
        );
      }
      log.recordError(
        'player.subtitle_selection.error',
        StateError('private_secret'),
        null,
        fields: {'sourceSessionId': 2, 'engine': 'media_kit'},
      );
      final data = await rows();
      expect(
        data
            .where((row) => row['event'] == 'playback.phase')
            .map((row) => row['operation']),
        ['fileResolve', 'playerSettings', 'historyOpen', 'routePush'],
      );
      expect(data.last['event'], 'player.subtitle_selection.error');
      expect(
        await (await log.export()).readAsString(),
        isNot(contains('private_secret')),
      );
    },
  );

  test(
    'never reads error messages and keeps only safe source stack frames',
    () async {
      await log.setEnabled(true);
      log.recordError(
        'flutter_error',
        const _MessageTrap(),
        StackTrace.fromString(
          '#0 private_secret (package:animewitcher/core/logger/app_diagnostics.dart:31:8)\n'
          '#1 private_secret (file:///Users/private_secret/home.dart:9:2)\n'
          '#2 private_secret (https://private_secret.example/a.dart?token=secret:9:2)\n'
          '#3 private_secret (package:animewitcher/../../private_secret.dart:9:2)\n'
          '#4 private_secret (package:animewitcher/a.dart?token=private_secret:9:2)\n'
          '#5 private_secret (package:dio/src/private_secret.dart:44:3)\n'
          '#6 private_secret (dart:async/future.dart:7:2)',
        ),
        fields: {'sourceSessionId': 4},
      );
      final content = await (await log.export()).readAsString();
      expect(content, isNot(contains('private_secret')));
      expect(content, isNot(contains('file://')));
      expect(content, isNot(contains('token=')));
      final row = (await rows()).last;
      expect(row['errorType'], 'UnknownError');
      expect(row['sourceSessionId'], 4);
      expect(row['stack'], [
        'package:animewitcher/core/logger/app_diagnostics.dart:31:8',
        'package:dio:44:3',
        'dart:async:7:2',
      ]);
    },
  );

  test(
    'oversized inputs and unsupported collections do not grow records',
    () async {
      await log.setEnabled(true);
      final large = 'private_secret' * 100000;
      log.record(large);
      log.record(
        'player.phase',
        fields: {
          'phase': large,
          'count': large,
          'status': ['private_secret'],
          'result': {'private_secret': true},
          'local': true,
        },
      );
      final content = await (await log.export()).readAsString();
      expect(content.length, lessThan(1024));
      expect(content, isNot(contains('private_secret')));
      expect((await rows()).last['local'], isTrue);
    },
  );

  test('bounds queue and reports rejected burst count on flush', () async {
    log = AppDiagnostics(
      directoryProvider: () async => Directory('${root.path}/logs'),
      exportDirectoryProvider: () async => Directory('${root.path}/exports'),
      maxPending: 4,
      now: () => now,
    );
    await log.setEnabled(true);
    await log.flush();
    for (var index = 0; index < 50; index++) {
      log.record('network_start', fields: {'request_id': index});
    }
    final data = await rows();
    expect(data.where((row) => row['event'] == 'network_start').length, 4);
    expect(data.last['event'], 'logging.dropped');
    expect(data.last['droppedEvents'], 46);
  });

  test(
    'suppresses duplicate bursts and applies a bounded per-second rate',
    () async {
      await log.setEnabled(true);
      await log.flush();
      for (var index = 0; index < 20; index++) {
        log.record('player.phase', fields: {'phase': 'openingSource'});
      }
      final first = await rows();
      expect(first.where((row) => row['event'] == 'player.phase').length, 1);
      expect(first.last['droppedEvents'], 19);
      now = now.add(const Duration(seconds: 1));
      for (var index = 0; index < 100; index++) {
        log.record('network_start', fields: {'request_id': index});
      }
      final second = await rows();
      expect(second.where((row) => row['event'] == 'network_start').length, 64);
      expect(second.last['droppedEvents'], 36);
    },
  );

  test(
    'rotates within byte and file bounds without touching other logs',
    () async {
      log = AppDiagnostics(
        directoryProvider: () async => Directory('${root.path}/logs'),
        exportDirectoryProvider: () async => Directory('${root.path}/exports'),
        maxBytes: 512,
        maxFiles: 3,
        now: () => now,
      );
      final folder = await log.directory();
      final unrelated = File('${folder.path}/download-secret.log');
      await unrelated.writeAsString('private_secret');
      await log.setEnabled(true);
      for (var index = 0; index < 60; index++) {
        now = now.add(const Duration(seconds: 1));
        log.record('network_finish', fields: {'request_id': index});
        await log.flush();
      }
      final files = await log.listFiles();
      expect(files.length, 3);
      for (final file in files) {
        expect(await file.length(), lessThanOrEqualTo(512));
      }
      expect(await unrelated.readAsString(), 'private_secret');
      final data = await rows();
      final ids = data
          .where((row) => row['event'] == 'network_finish')
          .map((row) => row['request_id'] as int)
          .toList();
      expect(ids, orderedEquals([...ids]..sort()));
      expect(ids.last, 59);
      expect(await (await log.export()).length(), lessThanOrEqualTo(1536));
      expect(
        await (await log.export()).readAsString(),
        isNot(contains('private_secret')),
      );
    },
  );

  test('write failures never escape and later writes recover', () async {
    await log.setEnabled(true);
    await log.flush();
    final folder = await log.directory();
    await folder.delete(recursive: true);
    await File(folder.path).writeAsString('blocked');
    log.recordError('platform_error', StateError('private_secret'), null);
    await log.flush();
    expect(log.lastError, isNotNull);
    expect(log.lastError.toString(), isNot(contains('private_secret')));
    await File(folder.path).delete();
    now = now.add(const Duration(seconds: 1));
    log.record('startup_phase', fields: {'phase': 'app_ready'});
    await log.flush();
    expect(log.lastError, isNull);
    expect((await rows()).last['phase'], 'app_ready');
  });

  test('clear removes owned rotated logs and cached export only', () async {
    final folder = await log.directory();
    for (final suffix in ['', '.1', '.2']) {
      await File('${folder.path}/app-diagnostics$suffix.jsonl')
          .writeAsString('old log\n');
    }
    final unrelated = File('${folder.path}/download.log');
    await unrelated.writeAsString('keep');
    final exported = await log.export();
    final savedCopy = await exported.copy('${root.path}/saved-log.jsonl');

    await log.clear();

    expect(log.enabled, isFalse);
    expect(await log.listFiles(), isEmpty);
    expect(await exported.exists(), isFalse);
    expect(await unrelated.readAsString(), 'keep');
    expect(await savedCopy.readAsString(), 'old log\n' * 3);
    expect(await rows(), isEmpty);
    await log.clear();
    expect(log.lastError, isNull);
  });

  test('clear keeps capture enabled and accepts the same event anew', () async {
    await log.setEnabled(true);
    log.record('navigation', fields: {'route': 'home'});
    await log.flush();
    log.record('navigation', fields: {'route': 'home'});

    await log.clear();

    expect(log.enabled, isTrue);
    expect(await log.listFiles(), isEmpty);
    log.record('navigation', fields: {'route': 'home'});
    final data = await rows();
    expect(data, hasLength(1));
    expect(data.single['event'], 'navigation');
    expect(data.single['route'], 'home');
  });

  test(
    'clear waits for in-flight writes and discards queued old events',
    () async {
      final gate = Completer<void>();
      final writing = Completer<void>();
      var stalled = false;
      log = AppDiagnostics(
        directoryProvider: () async {
          if (stalled) {
            if (!writing.isCompleted) writing.complete();
            await gate.future;
          }
          return Directory('${root.path}/logs');
        },
        exportDirectoryProvider: () async => Directory('${root.path}/exports'),
        now: () => now,
      );
      await log.setEnabled(true);
      await log.flush();
      stalled = true;
      log.record('navigation', fields: {'route': 'home'});
      final flushing = log.flush();
      await writing.future;
      log.record('navigation', fields: {'route': 'settings'});
      var cleared = false;
      final clearing = log.clear();
      unawaited(clearing.then((_) => cleared = true));
      expect(identical(log.clear(), clearing), isTrue);
      log.record('navigation', fields: {'route': 'search'});
      await Future<void>.delayed(Duration.zero);
      expect(cleared, isFalse);

      gate.complete();
      await flushing;
      await clearing;
      await log.flush();

      expect(log.enabled, isTrue);
      expect(await log.listFiles(), isEmpty);
      log.record('navigation', fields: {'route': 'downloads'});
      expect((await rows()).map((row) => row['route']), ['downloads']);
    },
  );

  test(
    'clear removes an export already in progress without stale data',
    () async {
      final gate = Completer<void>();
      final exporting = Completer<void>();
      var stalled = true;
      log = AppDiagnostics(
        directoryProvider: () async => Directory('${root.path}/logs'),
        exportDirectoryProvider: () async {
          if (stalled) {
            if (!exporting.isCompleted) exporting.complete();
            await gate.future;
          }
          return Directory('${root.path}/exports');
        },
      );
      await log.setEnabled(true);
      log.record('navigation', fields: {'route': 'home'});
      final export = log.export();
      await exporting.future;
      final clearing = log.clear();
      gate.complete();
      final exported = await export;
      await clearing;
      stalled = false;

      expect(await exported.exists(), isFalse);
      expect(await rows(), isEmpty);
    },
  );

  test('clear failures are reported safely and a retry can succeed', () async {
    await log.setEnabled(true);
    await log.flush();
    final folder = await log.directory();
    final active = File('${folder.path}/app-diagnostics.jsonl');
    await active.delete();
    await Directory(active.path).create();

    await expectLater(log.clear(), throwsA(isA<FileSystemException>()));
    expect(log.enabled, isTrue);
    expect(log.lastError, 'FileSystemException');

    await Directory(active.path).delete();
    log.record('navigation', fields: {'route': 'home'});
    await log.flush();
    expect(await log.listFiles(), isNotEmpty);
    await log.clear();
    expect(log.lastError, isNull);
    expect(await log.listFiles(), isEmpty);
  });

  test('clear refuses linked logs and never deletes their targets', () async {
    final folder = await log.directory();
    final target = File('${root.path}/private-file');
    await target.writeAsString('keep');
    await Link('${folder.path}/app-diagnostics.jsonl').create(target.path);

    await expectLater(log.clear(), throwsA(isA<FileSystemException>()));

    expect(await target.readAsString(), 'keep');
  });

  test('partial deletion reports failure and can be retried', () async {
    final folder = Directory('${root.path}/logs');
    final active = File('${folder.path}/app-diagnostics.jsonl');
    final rotated = File('${folder.path}/app-diagnostics.1.jsonl');
    var interfere = true;
    log = AppDiagnostics(
      directoryProvider: () async => folder,
      exportDirectoryProvider: () async {
        if (interfere) {
          await rotated.delete();
          await Directory(rotated.path).create();
          await File('${rotated.path}/blocker').writeAsString('keep');
        }
        return Directory('${root.path}/exports');
      },
    );
    await log.directory();
    await active.writeAsString('old log');
    await rotated.writeAsString('old log');

    await expectLater(log.clear(), throwsA(isA<FileSystemException>()));

    expect(await active.exists(), isFalse);
    expect(log.lastError, 'FileSystemException');
    interfere = false;
    await Directory(rotated.path).delete(recursive: true);
    await log.clear();
    expect(log.lastError, isNull);
    expect(await log.listFiles(), isEmpty);
  });

  test('enable failure remains disabled and can be retried', () async {
    await File('${root.path}/logs').writeAsString('blocked');
    await expectLater(
      log.setEnabled(true),
      throwsA(isA<FileSystemException>()),
    );
    expect(log.enabled, isFalse);
    expect(log.lastError, isNotNull);
    await File('${root.path}/logs').delete();
    await log.setEnabled(true);
    expect(log.enabled, isTrue);
    expect(log.lastError, isNull);
  });

  test(
    'batches are written automatically without caller awaiting record',
    () async {
      log = AppDiagnostics(
        directoryProvider: () async => Directory('${root.path}/logs'),
        exportDirectoryProvider: () async => Directory('${root.path}/exports'),
        flushInterval: const Duration(milliseconds: 1),
      );
      await log.setEnabled(true);
      log.record('navigation', fields: {'route': 'downloads'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final content = await (await log.listFiles()).first.readAsString();
      expect(content, contains('downloads'));
    },
  );
  test(
    'retains monotonic session timing when the wall clock moves back',
    () async {
      await log.setEnabled(true);
      log.record(
        'navigation',
        fields: {'route': 'home', 'sessionElapsedMs': 999999},
      );
      now = now.subtract(const Duration(days: 1));
      log.record('navigation', fields: {'route': 'settings'});
      final data = await rows();
      expect(data[1]['sequence'], lessThan(data[2]['sequence'] as int));
      expect(data[1]['sessionElapsedMs'], isA<int>());
      expect(data[1]['sessionElapsedMs'], isNot(999999));
      expect(
        data[2]['sessionElapsedMs'],
        greaterThanOrEqualTo(data[1]['sessionElapsedMs'] as int),
      );
    },
  );

  test(
    'coalesces flushes during stalled storage and drains later arrivals',
    () async {
      final gate = Completer<void>();
      var stalled = false;
      log = AppDiagnostics(
        directoryProvider: () async {
          if (stalled) await gate.future;
          return Directory('${root.path}/logs');
        },
        exportDirectoryProvider: () async => Directory('${root.path}/exports'),
        now: () => now,
      );
      await log.setEnabled(true);
      await log.flush();
      stalled = true;
      log.record('navigation', fields: {'route': 'home'});
      final flushing = log.flush();
      await Future<void>.delayed(Duration.zero);
      log.record('navigation', fields: {'route': 'settings'});
      for (var index = 0; index < 1000; index++) {
        expect(identical(log.flush(), flushing), isTrue);
      }
      gate.complete();
      await flushing;
      final data = await rows();
      expect(
        data
            .where((row) => row['event'] == 'navigation')
            .map((row) => row['route']),
        ['home', 'settings'],
      );
    },
  );
  test('disable completes while the writer is blocked on storage', () async {
    final gate = Completer<void>();
    var stalled = false;
    log = AppDiagnostics(
      directoryProvider: () async {
        if (stalled) await gate.future;
        return Directory('${root.path}/logs');
      },
      exportDirectoryProvider: () async => Directory('${root.path}/exports'),
    );
    await log.setEnabled(true);
    await log.flush();
    stalled = true;
    log.record('navigation', fields: {'route': 'home'});
    final flushing = log.flush();
    await Future<void>.delayed(Duration.zero);
    final disabling = log.setEnabled(false);
    expect(log.enabled, isFalse);
    await disabling.timeout(
      const Duration(milliseconds: 100),
      onTimeout: () {
        gate.complete();
        fail('disabling must not wait for storage');
      },
    );
    gate.complete();
    await flushing;
  });

  test(
    'refuses linked app log files without copying or modifying their target',
    () async {
      final folder = await log.directory();
      final target = File('${root.path}/private-file');
      await target.writeAsString('private_secret');
      final linked = Link('${folder.path}/app-diagnostics.jsonl');
      await linked.create(target.path);
      await log.setEnabled(true);
      log.record('navigation', fields: {'route': 'home'});
      await log.flush();
      expect(log.lastError, isNotNull);
      await expectLater(log.export(), throwsA(isA<FileSystemException>()));
      expect(await target.readAsString(), 'private_secret');
    },
  );

  test(
    'refuses linked export files and linked final log directories',
    () async {
      final target = File('${root.path}/private-file');
      await target.writeAsString('private_secret');
      final exports = Directory('${root.path}/exports');
      await exports.create();
      await Link('${exports.path}/app-diagnostics.jsonl').create(target.path);
      await log.setEnabled(true);
      log.record('navigation', fields: {'route': 'home'});
      await expectLater(log.export(), throwsA(isA<FileSystemException>()));
      expect(await target.readAsString(), 'private_secret');
      await log.setEnabled(false);
      await log.flush();
      await Directory('${root.path}/logs').delete(recursive: true);
      final external = Directory('${root.path}/external');
      await external.create();
      await Link('${root.path}/logs').create(external.path);
      await expectLater(
        log.setEnabled(true),
        throwsA(isA<FileSystemException>()),
      );
      expect(log.enabled, isFalse);
      expect(await external.list().toList(), isEmpty);
    },
  );
  test(
    'keeps known app error types without account codes or messages',
    () async {
      await log.setEnabled(true);
      log.recordError(
        'service_error',
        const AnimeWitcherAccountException('private_secret', 'private_secret'),
        null,
      );
      final data = await rows();
      expect(data.last['errorType'], 'AnimeWitcherAccountException');
      expect(
        await (await log.export()).readAsString(),
        isNot(contains('private_secret')),
      );
    },
  );

  test(
    'admits bounded application metadata without device identifiers',
    () async {
      await log.setEnabled(true);
      log.record(
        'app_metadata',
        fields: {
          'version_major': 1,
          'version_minor': 6,
          'version_patch': 3,
          'build': 5,
          'platform': 'ios',
          'build_mode': 'release',
          'device': 'private_secret',
          'packageId': 'private_secret',
        },
      );
      final row = (await rows()).last;
      expect(row['event'], 'app_metadata');
      expect(row['version_major'], 1);
      expect(row['version_minor'], 6);
      expect(row['version_patch'], 3);
      expect(row['build'], 5);
      expect(row['platform'], 'ios');
      expect(row['build_mode'], 'release');
      expect(
        await (await log.export()).readAsString(),
        isNot(contains('private_secret')),
      );
    },
  );
}

class _MessageTrap implements Exception {
  const _MessageTrap();

  @override
  String toString() => throw StateError('error messages must never be read');
}

import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _session = 'جلسة-🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪🧪';
const _logical = 'fixture-الحلقة';
const _time = 4242;

DownloadDiagnosticEventV2 _snapshot(
  int index, {
  DownloadTransportStatus status = DownloadTransportStatus.running,
}) => DownloadDiagnosticEventV2(
  logicalId: const DownloadLogicalId(_logical),
  generation: 1,
  taskId: 'اختبار-🧪-$index',
  status: status,
  progress: status == DownloadTransportStatus.complete ? 1 : 0.25,
);

File _active(Directory root, String name) =>
    File('${root.path}${Platform.pathSeparator}$name.jsonl');

typedef _Append = ({FileMode mode, bool flush});

final class _AuditIo extends IOOverrides {
  _AuditIo(this.path);
  final String path;
  final List<_Append> appends = [];

  @override
  File createFile(String name) {
    final file = super.createFile(name);
    return name == path ? _AuditedFile(file, appends) : file;
  }
}

/// Observe the append policy, then still write to the actual temporary file.
final class _AuditedFile implements File {
  _AuditedFile(this.file, this.appends);
  final File file;
  final List<_Append> appends;

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<int> length() => file.length();

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {
    appends.add((mode: mode, flush: flush));
    return file.writeAsBytes(bytes, mode: mode, flush: flush);
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    appends.add((mode: mode, flush: flush));
    return file.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final limit in [1, 3]) {
    test(
      'rotation budgets exact UTF-8 and retains newest $limit files',
      () async {
        final root = await Directory.systemTemp.createTemp('aw-jsonl-utf8-');
        addTearDown(() => root.delete(recursive: true));
        // Two such records fit by UTF-16 code units but not by UTF-8 bytes.
        // Exactly one record must be stored in each file.
        const byteBudget = 700;
        final log = FileDownloadDiagnosticsV2(
          directoryProvider: () async => root,
          enabled: () => true,
          nowMillis: () => _time,
          buildIdentityProvider: () async =>
              (version: '1.2.3', buildNumber: '4'),
          sessionId: _session,
          maxBytes: byteBudget,
          maxFiles: limit,
        );

        for (var i = 1; i <= 6; i++) {
          log.record(
            _snapshot(
              i,
              status: i == 6
                  ? DownloadTransportStatus.complete
                  : DownloadTransportStatus.running,
            ),
          );
        }
        await log.flush();
        expect(log.lastError, isNull);
        expect(await log.listFiles(), hasLength(limit));

        for (var i = 0; i < limit; i++) {
          final index = 6 - i;
          final bytes = await _active(
            root,
            i == 0 ? 'download_v2' : 'download_v2.$i',
          ).readAsBytes();
          final line = utf8.decode(bytes);
          expect(line, endsWith('\n'));
          expect(const LineSplitter().convert(line), hasLength(1));
          expect(bytes.length * 2, greaterThan(byteBudget));
          expect(line.length * 2, lessThanOrEqualTo(byteBudget));
          final actual = jsonDecode(line) as Map<String, dynamic>;
          final elapsed = actual['elapsedMs'];
          expect(elapsed, isA<int>());
          expect(elapsed as int, greaterThanOrEqualTo(0));
          final snapshot = _snapshot(
            index,
            status: index == 6
                ? DownloadTransportStatus.complete
                : DownloadTransportStatus.running,
          );
          final expected = <String, Object?>{
            'schemaVersion': 1,
            'appVersion': '1.2.3',
            'appBuildNumber': '4',
            'buildFingerprint': '1.2.3+4',
            'timestampMillis': _time,
            'sessionId': _session,
            'sequence': index,
            'elapsedMs': elapsed,
            'recordType': 'snapshot',
            'event': 'snapshot',
            ...snapshot.toJson(),
          };
          expect(
            bytes,
            orderedEquals(utf8.encode('${jsonEncode(expected)}\n')),
          );
        }
      },
    );
  }

  test('all lines append and only non-progress snapshots flush', () async {
    final root = await Directory.systemTemp.createTemp('aw-jsonl-append-');
    addTearDown(() => root.delete(recursive: true));
    final file = _active(root, 'download_v2');
    final audit = _AuditIo(file.path);
    await IOOverrides.runWithIOOverrides(() async {
      final log = FileDownloadDiagnosticsV2(
        directoryProvider: () async => root,
        enabled: () => true,
      );
      log.recordTransport('command.finished', {'taskId': 'fixture'});
      for (final status in DownloadTransportStatus.values) {
        log.record(_snapshot(status.index, status: status));
      }
      await log.flush();
      expect(log.lastError, isNull);
    }, audit);

    expect(
      audit.appends.map((write) => write.mode),
      everyElement(FileMode.append),
    );
    expect(audit.appends.map((write) => write.flush), [
      false,
      false,
      false,
      true,
      false,
      true,
      true,
      true,
      true,
    ]);
    expect(
      await file.readAsLines(),
      hasLength(1 + DownloadTransportStatus.values.length),
    );
  });

  test(
    'failed appends do not block later terminal writes or opt-out',
    () async {
      final root = await Directory.systemTemp.createTemp('aw-jsonl-retry-');
      addTearDown(() => root.delete(recursive: true));
      final active = _active(root, 'app');
      final obstacle = await Directory(active.path).create();
      var optedIn = false;
      var directoryCalls = 0;
      final log = FileDownloadDiagnosticsV2(
        directoryProvider: () async {
          directoryCalls++;
          return root;
        },
        enabled: () => optedIn,
        nowMillis: () => _time,
        sessionId: _session,
        fileName: 'app.jsonl',
      );

      log.record(_snapshot(0));
      await log.flush();
      expect(directoryCalls, 0);
      expect(log.lastError, isNull);

      optedIn = true;
      log.record(_snapshot(1));
      await log.flush();
      expect(directoryCalls, 1);
      expect(log.lastError, isA<FileSystemException>());

      await obstacle.delete();
      log.recordTransport('navigation.open', {
        'screen': 'details',
        'count': 2,
        'url': 'https://fixture.invalid/private',
      });
      log.record(_snapshot(3, status: DownloadTransportStatus.complete));
      optedIn = false;
      log.record(_snapshot(4, status: DownloadTransportStatus.failed));
      await log.flush();

      expect(directoryCalls, 3);
      expect(log.lastError, isNull);
      final rows = (await active.readAsLines())
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(rows.map((row) => row['sequence']), [2, 3]);
      expect(rows.map((row) => row['sessionId']), [_session, _session]);
      expect(rows.first['event'], 'navigation.open');
      expect(rows.first['count'], 2);
      expect(rows.first, isNot(contains('url')));
      expect(rows.last['status'], 'complete');
      expect(rows.last['taskId'], 'اختبار-🧪-3');
    },
  );
}

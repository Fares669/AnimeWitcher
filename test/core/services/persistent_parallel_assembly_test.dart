import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:animewitcher/core/utils/parallel_assembly_writer.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/parallel_download_fixtures.dart';

const _bufferBytes = 256 * 1024;
const _parts = 8;
const _partBytes = 2 * 1024 * 1024;
const _headroom = 256 * 1024 * 1024;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'verified ranges assemble across chunk boundaries with exact digest',
    () async {
      final result = await _assemble();
      expect(result.success, isTrue);
      expect(result.headroomChecks, _parts + 1);
      expect(result.digest, _fixtureSha);
      expect(result.checkpointDigest, _fixtureSha);
      expect(result.rangesRetained, _parts);
      expect(result.completions, 1);
    },
  );

  test(
    'a sibling writer leaves the existing large assembly path available',
    () async {
      final siblingDirectory = await Directory.systemTemp.createTemp(
        'parallel-assembly-sibling-',
      );
      try {
        final sibling = (await ParallelAssemblyWriter.tryOpen(
          '${siblingDirectory.path}/sibling.assembling',
          _partBytes,
          _bufferBytes,
        ))!;
        try {
          final result = await _assemble();
          expect(result.success, isTrue);
          expect(result.digest, _fixtureSha);
          expect(result.checkpointDigest, _fixtureSha);
          expect(result.completions, 1);
          expect(result.headroomChecks, _parts + 1);
        } finally {
          await sibling.close();
        }
      } finally {
        await siblingDirectory.delete(recursive: true);
      }
    },
  );

  for (final disturbance in ['shorter', 'longer', 'low-storage']) {
    test(
      'large assembly without publish on $disturbance range phase',
      () async {
        final result = await _assemble(disturbance: disturbance);
        expect(result.success, isFalse);
        expect(result.headroomChecks, 2);
        expect(result.rangesRetained, _parts);
        expect(result.completions, 0);
        expect(
          result.failures,
          disturbance == 'low-storage'
              ? [ParallelAssemblyFailureReason.insufficientStorage]
              : isEmpty,
        );
        if (disturbance == 'low-storage') {
          expect(result.stagingRetained, isFalse);
        }
      },
    );
  }
}

// Generated independently from the byte formula and exact range sizes below.
const _fixtureSha =
    '296a9964e43bb1a6214b343c1a33a69b0d030d0c50e8446bc059d77aeccf1fa8';

Future<
  ({
    bool success,
    String? digest,
    String? checkpointDigest,
    int headroomChecks,
    int rangesRetained,
    int completions,
    bool stagingRetained,
    List<ParallelAssemblyFailureReason> failures,
  })
>
_assemble({String? disturbance}) async {
  final directory = await Directory.systemTemp.createTemp('parallel-assembly-');
  final parent = ParallelDownloadTask(
    taskId: 'assembly-parent',
    url: 'https://assembly.invalid/episode',
    filename: 'episode.mp4',
    directory: directory.path,
    baseDirectory: BaseDirectory.root,
    chunks: _parts,
    allowPause: true,
  );
  final target = File(await parent.filePath());
  final manifest = File('${target.path}.parts/manifest.json');
  final staging = File('${target.path}.assembling');
  final chunks = <Map<String, Object?>>[];
  final sources = <File>[];
  var bytes = 0;
  var headroomChecks = 0;
  var rangesRetained = 0;
  var completions = 0;
  String? checkpointDigest;
  final failures = <ParallelAssemblyFailureReason>[];

  final coordinator = PersistentParallelDownload(
    verifyPartSource: verifiedSavedTestRange,
    promoteFile: (source, destination, length) async {
      final saved = jsonDecode(await manifest.readAsString()) as Map;
      checkpointDigest = (saved['readyToPublish'] as Map)['sha256'] as String?;
      for (final range in sources) {
        if (await range.exists()) rangesRetained++;
      }
      return publishCompletedTestFile(source, destination, length);
    },
    startPart: (_, _, _) async => throw StateError('Unexpected native start'),
    pausePart: (_) async {},
    cancelParts: (_) async {},
    saveRecord: (_) async {},
    recordForId: (_) async => null,
    onUpdate: (update) {
      if (update is TaskStatusUpdate && update.status == TaskStatus.complete) {
        completions++;
      }
    },
    onPartProgress: (_, _, _) {},
    onAssemblyFailure: (failure) => failures.add(failure.reason),
    availableStorageBytes: (_) async {
      headroomChecks++;
      if (headroomChecks == 2 && disturbance != null) {
        if (disturbance == 'low-storage') return 0;
        // The existing per-range size check has already accepted this file.
        final file = sources.first;
        final length = await file.length();
        final writer = await file.open(mode: FileMode.append);
        try {
          if (disturbance == 'shorter') {
            await writer.truncate(length - 1);
          } else {
            await writer.writeByte(0xaa);
          }
          await writer.flush();
        } finally {
          await writer.close();
        }
      }
      return _headroom;
    },
    livePartIds: () async => {},
  );

  try {
    for (var index = 0; index < _parts; index++) {
      final size = _partBytes + (index == 0 ? 0 : index * 113);
      final task = DownloadTask(
        taskId: 'range-$index',
        url: parent.url,
        filename: 'range-$index.part',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        headers: {'Range': 'bytes=$bytes-${bytes + size - 1}'},
      );
      final file = File(await task.filePath());
      sources.add(file);
      final pattern = Uint8List.fromList(
        List<int>.generate(
          _bufferBytes,
          (i) => ((i >> 8) ^ i ^ index * 13) & 255,
        ),
      );
      final writer = file.openSync(mode: FileMode.write);
      try {
        for (var sent = 0; sent < size; sent += pattern.length) {
          final remaining = size - sent;
          writer.writeFromSync(
            pattern,
            0,
            remaining < pattern.length ? remaining : pattern.length,
          );
        }
        writer.flushSync();
      } finally {
        writer.closeSync();
      }
      chunks.add({
        'task': task.toJson(),
        'fromByte': bytes,
        'toByte': bytes + size - 1,
        'progress': 1.0,
        'status': TaskStatus.complete.index,
      });
      bytes += size;
    }

    await coordinator.importLegacy(parent, jsonEncode(chunks));
    await coordinator.start(parent, bytes);
    await coordinator.flushPendingUpdates();
    final success = await target.exists();
    String? digest;
    if (success) {
      digest = (await sha256.bind(target.openRead()).first).toString();
    } else {
      for (final range in sources) {
        if (await range.exists()) rangesRetained++;
      }
    }
    return (
      success: success,
      digest: digest,
      checkpointDigest: checkpointDigest,
      headroomChecks: headroomChecks,
      rangesRetained: rangesRetained,
      completions: completions,
      stagingRetained: await staging.exists(),
      failures: failures,
    );
  } finally {
    await coordinator.dispose();
    await directory.delete(recursive: true);
  }
}

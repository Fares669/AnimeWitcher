from pathlib import Path
path = Path('lib/core/services/persistent_parallel_download.dart')
text = path.read_text()

old_comment = """/// Version 4 also persists whether a child must bypass old native resumeData
/// after its parent source URL was refreshed. Version 5 adds exact per-part
/// durable byte counters. Floating-point progress remains presentation/history
/// only and is never recovery byte authority.
const int kParallelManifestSchemaVersion = 5;
"""
new_comment = """/// Version 4 also persists whether a child must bypass old native resumeData
/// after its parent source URL was refreshed. Version 5 adds exact per-part
/// durable byte counters. Version 6 persists the logical parent task descriptor
/// so a surviving app-owned manifest can rebuild the logical startup inventory
/// without guessing a URL, headers, filename or base directory. Floating-point
/// progress remains presentation/history only and is never recovery byte authority.
const int kParallelManifestSchemaVersion = 6;

class ParallelManifestRecoveryEvidence {
  const ParallelManifestRecoveryEvidence({
    required this.task,
    required this.expectedBytes,
    required this.durableBytes,
    required this.updatedAtMillis,
    required this.manifestPath,
  });

  final ParallelDownloadTask task;
  final int expectedBytes;
  final int durableBytes;
  final int updatedAtMillis;
  final String manifestPath;

  double get progress => expectedBytes > 0
      ? (durableBytes / expectedBytes).clamp(0.0, 1.0).toDouble()
      : 0.0;
}

Future<ParallelManifestRecoveryEvidence?> readParallelManifestRecoveryEvidence(
  File manifest, {
  required Directory trustedRoot,
}) async {
  try {
    if (!await manifest.exists() || !await trustedRoot.exists()) return null;
    final rootPath = p.normalize(p.absolute(trustedRoot.path));
    final manifestPath = p.normalize(p.absolute(manifest.path));
    if (!p.isWithin(rootPath, manifestPath) ||
        p.basename(manifestPath) != 'manifest.json' ||
        !p.basename(p.dirname(manifestPath)).endsWith('.parts')) {
      return null;
    }

    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map) return null;
    final json = Map<String, dynamic>.from(decoded);
    final schemaVersion = (json['schemaVersion'] as num?)?.toInt() ?? 1;
    if (schemaVersion < 6 || schemaVersion > kParallelManifestSchemaVersion) {
      return null;
    }
    final rawParent = json['parentTask'];
    if (rawParent is! Map) return null;
    final restored = Task.createFromJson(Map<String, dynamic>.from(rawParent));
    if (restored is! ParallelDownloadTask) return null;
    final parentTaskId = json['parentTaskId']?.toString().trim() ?? '';
    if (parentTaskId.isEmpty || parentTaskId != restored.taskId) return null;

    final targetPath = p.normalize(p.absolute(await restored.filePath()));
    if (!p.isWithin(rootPath, targetPath)) return null;
    final expectedManifestPath = p.normalize(
      p.absolute('$targetPath.parts${p.separator}manifest.json'),
    );
    if (expectedManifestPath != manifestPath) return null;

    final expectedBytes =
        ((json['expectedBytes'] ?? json['totalBytes']) as num?)?.toInt() ?? -1;
    var durableBytes = 0;
    final rawParts = json['parts'];
    if (rawParts is List) {
      for (final rawPart in rawParts) {
        if (rawPart is! Map) continue;
        final bytes = (rawPart['durableBytes'] as num?)?.toInt() ?? 0;
        if (bytes > 0) durableBytes += bytes;
      }
    }
    if (expectedBytes > 0 && durableBytes > expectedBytes) {
      durableBytes = expectedBytes;
    }
    final stat = await manifest.stat();
    final updatedAtMillis =
        (json['updatedAtMillis'] as num?)?.toInt() ??
        stat.modified.millisecondsSinceEpoch;
    return ParallelManifestRecoveryEvidence(
      task: restored,
      expectedBytes: expectedBytes,
      durableBytes: durableBytes,
      updatedAtMillis: updatedAtMillis,
      manifestPath: manifestPath,
    );
  } catch (_) {
    return null;
  }
}

Future<List<ParallelManifestRecoveryEvidence>> discoverParallelManifestRecovery(
  Directory trustedRoot,
) async {
  if (!await trustedRoot.exists()) {
    return const <ParallelManifestRecoveryEvidence>[];
  }
  final byTaskId = <String, ParallelManifestRecoveryEvidence>{};
  await for (final entity in trustedRoot.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File || p.basename(entity.path) != 'manifest.json') continue;
    if (!p.basename(p.dirname(entity.path)).endsWith('.parts')) continue;
    final evidence = await readParallelManifestRecoveryEvidence(
      entity,
      trustedRoot: trustedRoot,
    );
    if (evidence == null) continue;
    final previous = byTaskId[evidence.task.taskId];
    if (previous == null ||
        evidence.updatedAtMillis > previous.updatedAtMillis) {
      byTaskId[evidence.task.taskId] = evidence;
    }
  }
  final result = byTaskId.values.toList(growable: false)
    ..sort((a, b) {
      final age = a.updatedAtMillis.compareTo(b.updatedAtMillis);
      if (age != 0) return age;
      return a.task.taskId.compareTo(b.task.taskId);
    });
  return result;
}
"""
if text.count(old_comment) != 1:
    raise SystemExit(f'manifest version block expected once, found {text.count(old_comment)}')
text = text.replace(old_comment, new_comment, 1)

old_payload = """      'schemaVersion': kParallelManifestSchemaVersion,
      'parentTaskId': session.task.taskId,
      'generation': session.generation,
"""
new_payload = """      'schemaVersion': kParallelManifestSchemaVersion,
      'parentTaskId': session.task.taskId,
      'parentTask': session.task.toJson(),
      'updatedAtMillis': DateTime.now().millisecondsSinceEpoch,
      'generation': session.generation,
"""
if text.count(old_payload) != 1:
    raise SystemExit(f'manifest payload block expected once, found {text.count(old_payload)}')
text = text.replace(old_payload, new_payload, 1)
path.write_text(text)

test_path = Path('test/core/services/persistent_parallel_download_test.dart')
tests = test_path.read_text()
marker = "  test('five parts cover each byte once', () async {\n"
extra = r"""  test('manifest discovery accepts only trusted v6 parent descriptors', () async {
    expect(await coordinator.start(parent, 100), isTrue);
    final manifest = File('${await parent.filePath()}.parts/manifest.json');

    final evidence = await readParallelManifestRecoveryEvidence(
      manifest,
      trustedRoot: directory,
    );
    expect(evidence, isNotNull);
    expect(evidence!.task.taskId, parent.taskId);
    expect(evidence.expectedBytes, 100);
    expect(evidence.durableBytes, 0);

    final discovered = await discoverParallelManifestRecovery(directory);
    expect(discovered.map((item) => item.task.taskId), [parent.taskId]);

    final legacy =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>
          ..['schemaVersion'] = 5
          ..remove('parentTask');
    await manifest.writeAsString(jsonEncode(legacy), flush: true);
    expect(
      await readParallelManifestRecoveryEvidence(
        manifest,
        trustedRoot: directory,
      ),
      isNull,
      reason: 'v5 manifests may resume a known parent but cannot invent one',
    );
  });

  test('manifest descriptor cannot escape or mismatch its app-owned target', () async {
    expect(await coordinator.start(parent, 100), isTrue);
    final manifest = File('${await parent.filePath()}.parts/manifest.json');
    final foreign = File('${directory.path}/foreign.parts/manifest.json');
    await foreign.parent.create(recursive: true);
    await foreign.writeAsString(await manifest.readAsString(), flush: true);

    expect(
      await readParallelManifestRecoveryEvidence(
        foreign,
        trustedRoot: directory,
      ),
      isNull,
    );

    final outside = await Directory.systemTemp.createTemp('parallel-outside-');
    try {
      final outsideManifest =
          File('${outside.path}/video.mp4.parts/manifest.json');
      await outsideManifest.parent.create(recursive: true);
      await outsideManifest.writeAsString(
        await manifest.readAsString(),
        flush: true,
      );
      expect(
        await readParallelManifestRecoveryEvidence(
          outsideManifest,
          trustedRoot: directory,
        ),
        isNull,
      );
    } finally {
      await outside.delete(recursive: true);
    }
  });

"""
if marker not in tests:
    raise SystemExit('extra test insertion marker not found')
tests = tests.replace(marker, extra + marker, 1)
test_path.write_text(tests)

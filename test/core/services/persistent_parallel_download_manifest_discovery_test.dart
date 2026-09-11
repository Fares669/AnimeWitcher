import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ParallelDownloadTask parent;
  late PersistentParallelDownload coordinator;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('parallel-discovery-');
    parent = ParallelDownloadTask(
      taskId: 'manifest-discovery-parent',
      url: 'https://example.test/episode.mp4',
      filename: 'episode.mp4',
      directory: root.path,
      baseDirectory: BaseDirectory.root,
      chunks: 2,
      allowPause: true,
      metaData: 'https://animewitcher.test/episode/7',
    );
    coordinator = PersistentParallelDownload(
      startPart: (_, _, _) async => true,
      pausePart: (_) async {},
      cancelParts: (_) async {},
      saveRecord: (_) async {},
      recordForId: (_) async => null,
      onUpdate: (_) {},
      onPartProgress: (_, _, _) {},
      livePartIds: () async => <String>{},
      diskProgressPollInterval: const Duration(seconds: 30),
    );
    expect(await coordinator.start(parent, 20), isTrue);
  });

  tearDown(() async {
    await coordinator.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> manifestFile() async =>
      File('${await parent.filePath()}.parts/manifest.json');

  test('discovers a v6 manifest as recoverable logical parent evidence', () async {
    final evidence = await discoverParallelManifestRecoveryEvidence(<Directory>[
      root,
    ]);

    expect(evidence, hasLength(1));
    final found = evidence.single;
    expect(found.schemaVersion, kParallelManifestSchemaVersion);
    expect(found.parentTaskId, parent.taskId);
    expect(found.parentTask, isNotNull);
    expect(found.parentTask!.taskId, parent.taskId);
    expect(found.parentTask!.metaData, parent.metaData);
    expect(found.expectedBytes, 20);
    expect(found.childTasks, hasLength(2));
  });

  test('legacy manifest remains explicit unresolved evidence, not guessed parent', () async {
    final manifest = await manifestFile();
    final snapshot =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    snapshot['schemaVersion'] = 5;
    snapshot.remove('parentTask');
    await manifest.writeAsString(jsonEncode(snapshot), flush: true);

    final evidence = await discoverParallelManifestRecoveryEvidence(<Directory>[
      root,
    ]);

    expect(evidence, hasLength(1));
    final found = evidence.single;
    expect(found.schemaVersion, 5);
    expect(found.parentTaskId, parent.taskId);
    expect(found.parentTask, isNull);
    expect(found.childTasks, hasLength(2));
    expect(
      found.childTasks.every((task) => task.taskId.startsWith('${parent.taskId}.part.')),
      isTrue,
    );
  });
}

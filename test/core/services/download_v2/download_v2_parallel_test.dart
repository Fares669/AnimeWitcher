import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parallelChunks 5 creates one package parent and persists no child ids', () {
    const spec = DownloadTaskSpecV2(
      taskId: 'aw_v2_parent_g1',
      url: 'https://cdn.example.invalid/video.mp4?token=secret',
      destinationPath: 'downloads/episode.mp4',
      headers: <String, String>{'authorization': 'Bearer secret'},
      allowPause: true,
      retries: 2,
      parallelChunks: 5,
    );

    final task = packageTaskForV2(spec);

    expect(task, isA<ParallelDownloadTask>());
    expect(task.taskId, spec.taskId);

    final record = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: const DownloadLogicalId('logical-episode'),
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
      generation: 1,
      taskId: spec.taskId,
      intent: DownloadUserIntent.active,
      destinationPath: spec.destinationPath,
      sourceDescriptor: const <String, Object?>{
        'providerId': 'provider.example',
        'episodeId': '12',
      },
      updatedAtMillis: 1,
    );

    final serializedKeys = record.toJson().keys.join('|').toLowerCase();
    expect(serializedKeys, isNot(contains('child')));
    expect(serializedKeys, isNot(contains('chunk')));
    expect(record.taskId, spec.taskId);
  });

  test('parallelChunks 1 maps to package single download task', () {
    const spec = DownloadTaskSpecV2(
      taskId: 'aw_v2_parent_g1',
      url: 'https://example.invalid/video.mp4',
      destinationPath: 'downloads/episode.mp4',
      headers: <String, String>{},
      allowPause: true,
      retries: 2,
      parallelChunks: 1,
    );

    final task = packageTaskForV2(spec);

    expect(task, isA<DownloadTask>());
    expect(task, isNot(isA<ParallelDownloadTask>()));
    expect(task.taskId, spec.taskId);
  });
}

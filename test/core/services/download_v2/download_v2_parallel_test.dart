import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parallelChunks 5 creates one package parent and persists no child ids', () async {
    const spec = DownloadTaskSpecV2(
      taskId: 'aw_v2_parent_g1',
      url: 'https://cdn.example.invalid/video.mp4?token=secret',
      destinationPath: 'downloads/episode.mp4',
      headers: <String, String>{'authorization': 'Bearer secret'},
      allowPause: true,
      retries: 2,
      parallelChunks: 5,
    );

    final task = await packageTaskForV2(spec);

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
    expect(serializedKeys, isNot(contains('chunkid')));
    expect(record.taskId, spec.taskId);
  });

  test('iOS preserves the requested parallel width for durable ranged transport', () async {
    const spec = DownloadTaskSpecV2(
      taskId: 'aw_v2_ios_parent_g1',
      url: 'https://example.invalid/video.mp4',
      destinationPath: 'downloads/episode-ios.mp4',
      headers: <String, String>{},
      allowPause: true,
      retries: 2,
      parallelChunks: 16,
    );

    expect(effectivePackageParallelChunksV2(16, isIOS: true), 16);
    expect(effectivePackageParallelChunksV2(16, isIOS: false), 16);

    final task = await packageTaskForV2(spec, isIOS: true);

    expect(task, isA<ParallelDownloadTask>());
    expect((task as ParallelDownloadTask).chunks, 16);
    expect(task.taskId, spec.taskId);
  });

  test('iOS one connection still maps to a durable ranged parent', () async {
    const spec = DownloadTaskSpecV2(
      taskId: 'aw_v2_ios_single_g1',
      url: 'https://example.invalid/video.mp4',
      destinationPath: 'downloads/episode-ios-single.mp4',
      headers: <String, String>{},
      allowPause: true,
      retries: 2,
      parallelChunks: 1,
    );

    final task = await packageTaskForV2(spec, isIOS: true);

    expect(task, isA<ParallelDownloadTask>());
    expect((task as ParallelDownloadTask).chunks, 1);
    expect(task.taskId, spec.taskId);
  });

  test('parallelChunks 1 maps to package single download task', () async {
    const spec = DownloadTaskSpecV2(
      taskId: 'aw_v2_parent_g1',
      url: 'https://example.invalid/video.mp4',
      destinationPath: 'downloads/episode.mp4',
      headers: <String, String>{},
      allowPause: true,
      retries: 2,
      parallelChunks: 1,
    );

    final task = await packageTaskForV2(spec);

    expect(task, isA<DownloadTask>());
    expect(task, isNot(isA<ParallelDownloadTask>()));
    expect(task.taskId, spec.taskId);
  });
}

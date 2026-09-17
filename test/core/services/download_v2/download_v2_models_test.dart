import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';

void main() {
  LogicalDownloadRecordV2 record({
    DownloadUserIntent intent = DownloadUserIntent.active,
    int? completedAtMillis,
    DownloadFailureCategory? failureCategory,
    String? failureMessage,
    bool allowPause = true,
    int retries = 2,
    int parallelChunks = 1,
  }) {
    final logicalId = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );
    return LogicalDownloadRecordV2(
      schemaVersion: 1,
      logicalId: logicalId,
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
      generation: 1,
      taskId: taskIdForGeneration(logicalId, 1),
      intent: intent,
      destinationPath: 'downloads/anime/episode-12.mp4',
      sourceDescriptor: const <String, Object?>{
        'providerId': 'provider.example',
        'trackingUrl': '/anime/21/12',
      },
      expectedBytes: 123456,
      completedAtMillis: completedAtMillis,
      failureCategory: failureCategory,
      failureMessage: failureMessage,
      allowPause: allowPause,
      retries: retries,
      parallelChunks: parallelChunks,
      updatedAtMillis: 1234,
    );
  }

  test('logical record round-trips application-owned metadata', () {
    final original = record(
      intent: DownloadUserIntent.paused,
      allowPause: false,
      retries: 4,
      parallelChunks: 5,
    );
    final decoded = LogicalDownloadRecordV2.fromJson(original.toJson());

    expect(decoded, isNotNull);
    expect(decoded!.logicalId, original.logicalId);
    expect(decoded.taskId, original.taskId);
    expect(decoded.generation, 1);
    expect(decoded.intent, DownloadUserIntent.paused);
    expect(decoded.destinationPath, original.destinationPath);
    expect(decoded.sourceDescriptor, original.sourceDescriptor);
    expect(decoded.expectedBytes, 123456);
    expect(decoded.allowPause, isFalse);
    expect(decoded.retries, 4);
    expect(decoded.parallelChunks, 5);
  });

  test('legacy V2 record defaults missing application policy safely', () {
    final json = record().toJson()
      ..remove('allowPause')
      ..remove('retries')
      ..remove('parallelChunks');

    final decoded = LogicalDownloadRecordV2.fromJson(json);

    expect(decoded, isNotNull);
    expect(decoded!.allowPause, isTrue);
    expect(decoded.retries, 2);
    expect(decoded.parallelChunks, 1);
  });

  test('serialized logical record contains no transport internals', () {
    final keys = record().toJson().keys.join('|').toLowerCase();

    for (final forbidden in <String>[
      'range',
      'resumebytes',
      'ownership',
      'retryremaining',
      'holdreason',
      'childtask',
    ]) {
      expect(keys, isNot(contains(forbidden)));
    }
  });

  test('copyWith changes user intent without changing generation identity', () {
    final original = record(parallelChunks: 5);
    final paused = original.copyWith(
      intent: DownloadUserIntent.paused,
      updatedAtMillis: 5678,
    );

    expect(paused.intent, DownloadUserIntent.paused);
    expect(paused.logicalId, original.logicalId);
    expect(paused.taskId, original.taskId);
    expect(paused.generation, original.generation);
    expect(paused.parallelChunks, 5);
    expect(paused.updatedAtMillis, 5678);
  });

  test('copyWith can explicitly clear stale completion and failure metadata', () {
    final terminal = record(
      completedAtMillis: 9999,
      failureCategory: DownloadFailureCategory.integrity,
      failureMessage: 'bad file',
    );

    final restarted = terminal.copyWith(
      clearCompletedAtMillis: true,
      clearFailure: true,
      updatedAtMillis: 10000,
    );

    expect(restarted.completedAtMillis, isNull);
    expect(restarted.failureCategory, isNull);
    expect(restarted.failureMessage, isNull);
  });

  test('transport snapshot final-state classification is explicit', () {
    expect(
      const DownloadTransportSnapshot(
        taskId: 'x',
        status: DownloadTransportStatus.running,
        progress: 0.5,
      ).isFinal,
      isFalse,
    );
    expect(
      const DownloadTransportSnapshot(
        taskId: 'x',
        status: DownloadTransportStatus.complete,
        progress: 1,
      ).isFinal,
      isTrue,
    );
    expect(
      const DownloadTransportSnapshot(
        taskId: 'x',
        status: DownloadTransportStatus.failed,
        progress: 0.5,
      ).isFinal,
      isTrue,
    );
  });
}

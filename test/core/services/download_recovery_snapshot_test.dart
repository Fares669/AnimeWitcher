import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_job_store.dart';
import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask _task(String id) => DownloadTask(
  taskId: id,
  url: 'https://cdn.example/$id.mp4',
  filename: '$id.mp4',
  group: kLogicalDownloadGroup,
  metaData: 'tracking://$id',
);

DownloadJobRecord _job(
  DownloadTask task, {
  DownloadJobState state = DownloadJobState.interrupted,
}) => DownloadJobRecord(
  taskId: task.taskId,
  trackingUrl: task.metaData,
  state: state,
  generation: 2,
  durableBytes: 400,
  durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
  expectedBytes: 1000,
  userPaused: false,
  queueWaiting: false,
  updatedAtMillis: 1234,
  taskSnapshot: task.toJson(),
);

void main() {
  group('durable task recovery snapshot', () {
    test('DownloadJobRecord round-trips enough task identity to rebuild work', () {
      final original = _task('job-only');
      final decoded = DownloadJobRecord.fromJson(_job(original).toJson());

      expect(decoded, isNotNull);
      final restored = decoded!.restoreTaskSnapshot();
      expect(restored, isA<DownloadTask>());
      expect(restored!.taskId, original.taskId);
      expect(restored.url, original.url);
      expect(restored.filename, original.filename);
      expect(restored.group, kLogicalDownloadGroup);
      expect(restored.metaData, original.metaData);
    });

    test('legacy JobStore rows without a task snapshot remain readable', () {
      final raw = _job(_task('legacy')).toJson()..remove('taskSnapshot');
      final decoded = DownloadJobRecord.fromJson(raw);

      expect(decoded, isNotNull);
      expect(decoded!.taskSnapshot, isNull);
      expect(decoded.restoreTaskSnapshot(), isNull);
    });

    test('terminal canceled snapshot stays terminal and is never recovery work', () {
      final canceled = DownloadJobRecord.fromJson(
        _job(_task('canceled'), state: DownloadJobState.canceled).toJson(),
      );

      expect(canceled, isNotNull);
      expect(canceled!.state, DownloadJobState.canceled);
      expect(canceled.restoreTaskSnapshot(), isNotNull);
    });
  });
}

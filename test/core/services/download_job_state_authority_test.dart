import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DM-05 DownloadJobState lifecycle authority', () {
    test(
      'authoritative running ignores stale legacy pause and plugin completion',
      () {
        final plan = planDownloadRecoveryWithJobAuthority(
          persisted: TaskStatus.complete,
          queueWaiting: true,
          userPaused: true,
          stillInNativeQueue: true,
          hasMetadata: true,
          authoritativeState: DownloadJobState.running,
          authoritativeUserPaused: false,
          authoritativeQueueWaiting: false,
        );

        expect(plan.state, DownloadJobState.running);
        expect(plan.action, DownloadRecoveryAction.keepNative);
      },
    );

    test(
      'authoritative queued ignores stale legacy pause and plugin cancellation',
      () {
        final plan = planDownloadRecoveryWithJobAuthority(
          persisted: TaskStatus.canceled,
          queueWaiting: false,
          userPaused: true,
          stillInNativeQueue: false,
          hasMetadata: true,
          authoritativeState: DownloadJobState.queued,
          authoritativeUserPaused: false,
          authoritativeQueueWaiting: true,
        );

        expect(plan.state, DownloadJobState.queued);
        expect(plan.action, DownloadRecoveryAction.requeue);
      },
    );
  });
}

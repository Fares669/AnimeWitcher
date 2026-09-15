import 'package:animewitcher/core/services/background_downloader_transport.dart';
import 'package:animewitcher/core/services/download_transport_policy.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Android download execution policy', () {
    test('notifications allowed single transfer can request UIDT', () {
      final policy = planAndroidDownloadExecutionPolicy(
        connections: 1,
        pluginParallelAccepted: false,
        legacySessionExists: false,
        notificationsConfigured: true,
        notificationPermissionGranted: true,
        expectedBytes: kDownloadLargeFileHintThresholdBytes,
      );

      expect(policy.backend, DownloadExecutionBackend.pluginSingle);
      expect(policy.transferHints, contains(TransferHint.userInitiated));
      expect(policy.transferHints, contains(TransferHint.largeFile));
    });

    test('notifications denied uses resumable non-UIDT single fallback', () {
      final policy = planAndroidDownloadExecutionPolicy(
        connections: 1,
        pluginParallelAccepted: false,
        legacySessionExists: false,
        notificationsConfigured: true,
        notificationPermissionGranted: false,
        expectedBytes: kDownloadLargeFileHintThresholdBytes,
      );

      expect(policy.backend, DownloadExecutionBackend.pluginSingle);
      expect(policy.transferHints, isNot(contains(TransferHint.userInitiated)));
      expect(policy.transferHints, contains(TransferHint.largeFile));
    });

    test('disabled notifications never request UIDT', () {
      final policy = planAndroidDownloadExecutionPolicy(
        connections: 1,
        pluginParallelAccepted: false,
        legacySessionExists: false,
        notificationsConfigured: false,
        notificationPermissionGranted: true,
        expectedBytes: 10 * 1024 * 1024,
      );

      expect(policy.backend, DownloadExecutionBackend.pluginSingle);
      expect(policy.transferHints, isNot(contains(TransferHint.userInitiated)));
    });

    test('multiple connections use plugin parallel only after Android acceptance', () {
      final accepted = planAndroidDownloadExecutionPolicy(
        connections: 8,
        pluginParallelAccepted: true,
        legacySessionExists: false,
        notificationsConfigured: true,
        notificationPermissionGranted: true,
        expectedBytes: 200 * 1024 * 1024,
      );
      final closed = planAndroidDownloadExecutionPolicy(
        connections: 8,
        pluginParallelAccepted: false,
        legacySessionExists: false,
        notificationsConfigured: true,
        notificationPermissionGranted: true,
        expectedBytes: 200 * 1024 * 1024,
      );

      expect(accepted.backend, DownloadExecutionBackend.pluginParallel);
      expect(closed.backend, DownloadExecutionBackend.legacyParallel);
    });

    test('legacy multipart evidence remains authoritative on Android', () {
      final policy = planAndroidDownloadExecutionPolicy(
        connections: 8,
        pluginParallelAccepted: true,
        legacySessionExists: true,
        notificationsConfigured: true,
        notificationPermissionGranted: true,
        expectedBytes: 200 * 1024 * 1024,
      );

      expect(policy.backend, DownloadExecutionBackend.legacyParallel);
    });
  });
}

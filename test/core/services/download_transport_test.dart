import 'package:animewitcher/core/services/download_transport.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normal DownloadTask routes through native single transport', () {
    final task = DownloadTask(
      taskId: 'single-1',
      url: 'https://example.test/episode.mp4',
      filename: 'episode.mp4',
    );
    expect(isNativeSingleDownloadTask(task), isTrue);
  });

  test('ParallelDownloadTask stays owned by multipart engine', () {
    final task = ParallelDownloadTask(
      taskId: 'parallel-1',
      url: 'https://example.test/episode.mp4',
      filename: 'episode.mp4',
      chunks: 4,
    );
    expect(isNativeSingleDownloadTask(task), isFalse);
  });

  test('Android notification-off falls back without UIDT', () {
    final useUserInitiated = shouldUseUserInitiatedDownloadHint(
      isAndroid: true,
      notificationsConfigured: false,
      notificationPermissionGranted: true,
    );
    final hints = animeDownloadTransferHints(
      expectedBytes: 900 * 1024 * 1024,
      useUserInitiated: useUserInitiated,
    );

    expect(useUserInitiated, isFalse);
    expect(hints, isNot(contains(TransferHint.userInitiated)));
    expect(hints, contains(TransferHint.largeFile));
  });

  test('Android denied notification permission falls back without UIDT', () {
    final useUserInitiated = shouldUseUserInitiatedDownloadHint(
      isAndroid: true,
      notificationsConfigured: true,
      notificationPermissionGranted: false,
    );
    final hints = animeDownloadTransferHints(
      expectedBytes: 900 * 1024 * 1024,
      useUserInitiated: useUserInitiated,
    );

    expect(useUserInitiated, isFalse);
    expect(hints, isNot(contains(TransferHint.userInitiated)));
    expect(hints, contains(TransferHint.largeFile));
  });

  test('Android notification-enabled keeps UIDT policy', () {
    final useUserInitiated = shouldUseUserInitiatedDownloadHint(
      isAndroid: true,
      notificationsConfigured: true,
      notificationPermissionGranted: true,
    );
    final hints = animeDownloadTransferHints(
      expectedBytes: 900 * 1024 * 1024,
      useUserInitiated: useUserInitiated,
    );

    expect(useUserInitiated, isTrue);
    expect(hints, contains(TransferHint.userInitiated));
    expect(hints, contains(TransferHint.largeFile));
  });

  test(
    'non-Android keeps user-initiated priority without Android notification policy',
    () {
      expect(
        shouldUseUserInitiatedDownloadHint(
          isAndroid: false,
          notificationsConfigured: false,
          notificationPermissionGranted: false,
        ),
        isTrue,
      );
    },
  );

  test('anime transfers request user initiated and large file hints', () {
    final hints = animeDownloadTransferHints(expectedBytes: 900 * 1024 * 1024);
    expect(hints, contains(TransferHint.userInitiated));
    expect(hints, contains(TransferHint.largeFile));
    expect(hints, isNot(contains(TransferHint.smallFile)));
  });
}

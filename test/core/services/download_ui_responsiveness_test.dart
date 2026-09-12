import 'dart:io';

import 'package:animewitcher/core/services/download_service.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadProgressData sample(double progress, double speed) =>
    DownloadProgressData(
      taskId: 'task',
      progress: progress,
      networkSpeed: speed,
      timeRemaining: const Duration(seconds: 20),
      totalSize: 1000,
      status: TaskStatus.running,
    );

void main() {
  test('running download metrics publish at most once per second', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(downloadProgressProvider.notifier);

    notifier.update('url', sample(0.10, 1));
    notifier.update('url', sample(0.20, 2));
    notifier.update('url', sample(0.30, 3));

    expect(container.read(downloadProgressProvider)['url']!.progress, 0.10);
    expect(container.read(downloadProgressProvider)['url']!.networkSpeed, 1);

    await Future<void>.delayed(const Duration(milliseconds: 1100));

    expect(container.read(downloadProgressProvider)['url']!.progress, 0.30);
    expect(container.read(downloadProgressProvider)['url']!.networkSpeed, 3);
  });

  test('pause status bypasses the one-second running metric throttle', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(downloadProgressProvider.notifier);

    notifier.update('url', sample(0.10, 1));
    notifier.update(
      'url',
      DownloadProgressData(
        taskId: 'task',
        progress: 0.10,
        networkSpeed: 0,
        timeRemaining: Duration.zero,
        totalSize: 1000,
        status: TaskStatus.paused,
      ),
    );

    expect(
      container.read(downloadProgressProvider)['url']!.status,
      TaskStatus.paused,
    );
  });

  test('delete waits for typed ownership settlement before destructive cleanup', () {
    final source = File(
      'lib/features/library/presentation/downloads_provider.dart',
    ).readAsStringSync();
    final method = source.substring(
      source.indexOf('Future<void> removeDownloads'),
    );

    final typedCancel = method.indexOf('.cancelDownloadOutcome(');
    final failClosed = method.indexOf('if (!safeToDestroy)', typedCancel);
    final deletingIds = method.indexOf(
      '_deletingIds.addAll(droppedIds)',
      failClosed,
    );
    final hiddenState = method.indexOf('state = AsyncData(', deletingIds);
    final fileDelete = method.indexOf('.deleteDownloadedFile(file)', hiddenState);

    expect(typedCancel, greaterThanOrEqualTo(0));
    expect(failClosed, greaterThan(typedCancel));
    expect(deletingIds, greaterThan(failClosed));
    expect(hiddenState, greaterThan(deletingIds));
    expect(fileDelete, greaterThan(hiddenState));
    expect(
      method,
      contains(
        'onTimeout: () => DownloadCommandOutcome.settlingOwnership',
      ),
    );
    expect(method, contains('state = AsyncData(await _refreshList());'));
  });
}

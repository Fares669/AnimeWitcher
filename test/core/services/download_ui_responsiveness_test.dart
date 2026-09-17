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

  test('delete hides a V2 row after manager deletion', () {
    final source = File(
      'lib/features/library/presentation/downloads_provider.dart',
    ).readAsStringSync();
    final methodStart = source.indexOf('Future<void> removeDownloads');
    expect(methodStart, greaterThanOrEqualTo(0));
    final method = source.substring(methodStart);

    final v2Delete = method.indexOf(
      'manager.delete(DownloadLogicalId(logical))',
    );
    final deletingIds = method.indexOf(
      '_deletingIds.addAll(droppedIds)',
      v2Delete,
    );
    final hiddenState = method.indexOf('state = AsyncData(', deletingIds);

    expect(v2Delete, greaterThanOrEqualTo(0));
    expect(deletingIds, greaterThan(v2Delete));
    expect(hiddenState, greaterThan(deletingIds));
    expect(method, contains('if (item.v2Owned && logical != null'));
    expect(method, contains('state = AsyncData('));
    expect(method, contains('storage.removeDownloadMetadata('));
    expect(
      method,
      isNot(contains('FileDownloader().database.deleteRecordWithId')),
    );
    expect(method, isNot(contains('.deleteDownloadedFile(')));
  });
}

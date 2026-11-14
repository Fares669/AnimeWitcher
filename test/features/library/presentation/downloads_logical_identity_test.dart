import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadItem _download({
  required String taskId,
  String? logicalId,
  String trackingUrl = '',
  String destinationPath = '',
  String? provider,
  TaskStatus status = TaskStatus.running,
}) {
  return DownloadItem(
    task: DownloadTask(
      taskId: taskId,
      url: 'https://example.test/$taskId',
      filename: '$taskId.mp4',
    ),
    status: status,
    progress: 0.5,
    item: MultimediaItem(
      title: 'Show',
      url: 'anime://show',
      posterUrl: '',
      provider: provider,
    ),
    logicalId: logicalId,
    trackingUrl: trackingUrl,
    destinationPath: destinationPath,
    timestamp: 1,
  );
}

void main() {
  group('V2 downloads UI logical identity', () {
    test('same tracking URL remains separate across providers', () {
      final first = _download(
        taskId: 'first',
        trackingUrl: 'episode://same',
        status: TaskStatus.complete,
      );
      final second = _download(
        taskId: 'second',
        trackingUrl: 'episode://same',
        provider: 'animerift',
        status: TaskStatus.complete,
      );
      final episode = Episode(name: 'one', url: 'episode://same');
      final rift = MultimediaItem(
        title: 'Show',
        url: 'anime://show',
        posterUrl: '',
        provider: 'animerift',
      );
      expect(downloadsPointAtSameTarget(first, second), isFalse);
      expect(groupDownloadsByEpisodeOrFile([first, second]), hasLength(2));
      expect(
        completedEpisodeDownload([first, second], rift, episode),
        same(second),
      );
    });

    test(
      'known different logical ids do not fall through to fallback matching',
      () {
        final first = _download(
          taskId: 'first',
          logicalId: 'logical-a',
          trackingUrl: 'episode://same',
          destinationPath: '/Downloads/same.mp4',
        );
        final second = _download(
          taskId: 'second',
          logicalId: 'logical-b',
          trackingUrl: 'episode://same',
          destinationPath: '/Downloads/same.mp4',
        );

        expect(downloadsPointAtSameTarget(first, second), isFalse);
      },
    );

    test('same logical id groups rows even when transport details differ', () {
      final first = _download(
        taskId: 'first',
        logicalId: 'logical-a',
        trackingUrl: 'episode://one',
        destinationPath: '/Downloads/one.mp4',
      );
      final second = _download(
        taskId: 'second',
        logicalId: 'logical-a',
        trackingUrl: 'episode://two',
        destinationPath: '/Downloads/two.mp4',
      );

      final groups = groupDownloadsByEpisodeOrFile([first, second]);

      expect(groups, hasLength(1));
      expect(groups.single, containsAll(<DownloadItem>[first, second]));
    });

    test(
      'tracking and file fallback is used only when logical id is absent',
      () {
        final byTrackingA = _download(
          taskId: 'tracking-a',
          trackingUrl: 'episode://same',
        );
        final byTrackingB = _download(
          taskId: 'tracking-b',
          trackingUrl: 'episode://same',
        );
        final byFileA = _download(
          taskId: 'file-a',
          destinationPath: '/Downloads/same.mp4',
        );
        final byFileB = _download(
          taskId: 'file-b',
          destinationPath: '/Downloads/same.mp4',
        );

        final groups = groupDownloadsByEpisodeOrFile([
          byTrackingA,
          byTrackingB,
          byFileA,
          byFileB,
        ]);

        expect(groups, hasLength(2));
        expect(
          groups.any(
            (group) =>
                group.contains(byTrackingA) && group.contains(byTrackingB),
          ),
          isTrue,
        );
        expect(
          groups.any(
            (group) => group.contains(byFileA) && group.contains(byFileB),
          ),
          isTrue,
        );
      },
    );
  });
}

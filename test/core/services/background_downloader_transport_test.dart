import 'package:animewitcher/core/services/background_downloader_transport.dart';
import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('background downloader transport task classification', () {
    test('accepts ordinary logical DownloadTask', () {
      final task = DownloadTask(
        taskId: 'episode-single',
        url: 'https://example.test/video.mp4',
        filename: 'episode.mp4',
        group: kLogicalDownloadGroup,
      );

      expect(isBackgroundDownloaderTransportTask(task), isTrue);
    });

    test('accepts logical ParallelDownloadTask', () {
      final task = ParallelDownloadTask(
        taskId: 'episode-parallel',
        url: 'https://example.test/video.mp4',
        filename: 'episode.mp4',
        group: kLogicalDownloadGroup,
        chunks: 4,
      );

      expect(isBackgroundDownloaderTransportTask(task), isTrue);
    });

    test('rejects legacy multipart child tasks', () {
      final task = DownloadTask(
        taskId: 'legacy-part',
        url: 'https://example.test/video.mp4',
        filename: 'episode.part1',
        group: kPersistentDownloadChunkGroup,
      );

      expect(isBackgroundDownloaderTransportTask(task), isFalse);
    });

    test('rejects plugin internal chunk tasks', () {
      final task = DownloadTask(
        taskId: 'plugin-chunk',
        url: 'https://example.test/video.mp4',
        filename: 'episode.part2',
        group: FileDownloader.chunkGroup,
      );

      expect(isBackgroundDownloaderTransportTask(task), isFalse);
    });
  });
}

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('adaptive parallel downloads', () {
    test('normalizes manual values through sixteen and junk to Auto', () {
      for (var value = 0; value <= 16; value++) {
        expect(normalizeDownloadPartPreference(value), value);
      }
      expect(normalizeDownloadPartPreference(null), 0);
      expect(normalizeDownloadPartPreference(17), 0);
      expect(normalizeDownloadPartPreference(99), 0);
    });

    test('Manga Auto uses four requests and preserves explicit widths', () {
      expect(mangaChapterPageConnectionsFromPreference(0), 4);
      expect(mangaChapterPageConnectionsFromPreference(1), 1);
      expect(mangaChapterPageConnectionsFromPreference(16), 16);
    });

    test('never splits without proven Range support and size', () {
      expect(
        selectAdaptiveDownloadParts(
          preference: 16,
          totalBytes: 900 * 1024 * 1024,
          supportsRanges: false,
        ),
        1,
      );
      expect(
        selectAdaptiveDownloadParts(
          preference: 16,
          totalBytes: -1,
          supportsRanges: true,
        ),
        1,
      );
    });

    test('Auto grows conservatively to sixteen connections', () {
      const mib = 1024 * 1024;
      final cases = <(int, int)>[
        (99, 1),
        (100, 2),
        (199, 2),
        (200, 4),
        (399, 4),
        (400, 8),
        (799, 8),
        (800, 16),
        (2048, 16),
      ];
      for (final (sizeMiB, expected) in cases) {
        expect(
          selectAdaptiveDownloadParts(
            preference: 0,
            totalBytes: sizeMiB * mib,
            supportsRanges: true,
          ),
          expected,
        );
      }
    });

    test('iOS V2 preserves manual width when metadata Range support is inconclusive', () {
      const mib = 1024 * 1024;
      expect(
        selectV2DownloadParts(
          preference: 16,
          totalBytes: 392 * mib,
          metadataSupportsRanges: false,
          isIOS: true,
        ),
        16,
      );
      expect(
        selectV2DownloadParts(
          preference: 16,
          totalBytes: 392 * mib,
          metadataSupportsRanges: false,
          isIOS: false,
        ),
        1,
      );
    });

    test('iOS V2 Auto may request a probe-worthy width before Range is proven', () {
      const mib = 1024 * 1024;
      expect(
        selectV2DownloadParts(
          preference: 0,
          totalBytes: 392 * mib,
          metadataSupportsRanges: false,
          isIOS: true,
        ),
        4,
      );
      expect(
        selectV2DownloadParts(
          preference: 0,
          totalBytes: 99 * mib,
          metadataSupportsRanges: false,
          isIOS: true,
        ),
        1,
      );
    });

    test('manual preference can request the full sixteen', () {
      const mib = 1024 * 1024;
      expect(
        selectAdaptiveDownloadParts(
          preference: 16,
          totalBytes: 2 * 1024 * mib,
          supportsRanges: true,
        ),
        16,
      );
    });

    test('legacy preference helper preserves the selected width', () {
      expect(
        effectiveDownloadPartsForPlatform(selectedParts: 16, isIOS: true),
        16,
      );
      expect(
        effectiveDownloadPartsForPlatform(selectedParts: 8, isIOS: true),
        8,
      );
      expect(
        effectiveDownloadPartsForPlatform(selectedParts: 1, isIOS: true),
        1,
      );
      expect(
        effectiveDownloadPartsForPlatform(selectedParts: 16, isIOS: false),
        16,
      );
    });

    test('large ranges keep spare tail work without adding connections', () {
      const mib = 1024 * 1024;
      expect(
        selectDownloadWorkUnitCount(connections: 4, totalBytes: 4 * mib),
        8,
      );
      expect(
        selectDownloadWorkUnitCount(connections: 16, totalBytes: 16 * mib),
        32,
      );
      expect(kDownloadWorkUnitsMax, 128);
    });

    test('tail work never creates tiny extra ranges', () {
      const mib = 1024 * 1024;
      expect(
        selectDownloadWorkUnitCount(connections: 16, totalBytes: 4 * mib),
        16,
      );
      expect(
        selectDownloadWorkUnitCount(connections: 1, totalBytes: 2 * 1024 * mib),
        128,
        reason:
            'one native writer still needs a bounded durable work queue; '
            'connection count and checkpoint count are separate concerns',
      );
    });

    test('Gopeed-style ramp reaches sixteen as 1, 2, 4, 8, 1', () {
      expect(downloadConnectionRampBatches(1), [1]);
      expect(downloadConnectionRampBatches(4), [1, 2, 1]);
      expect(downloadConnectionRampBatches(8), [1, 2, 4, 1]);
      expect(downloadConnectionRampBatches(16), [1, 2, 4, 8, 1]);
      expect(downloadConnectionRampBatches(99), [1, 2, 4, 8, 1]);
    });

    test('builds one logical parent with the same taskId', () {
      final normal = DownloadTask(
        taskId: 'episode-12',
        url: 'https://example.com/episode.mp4',
        filename: 'episode.mp4',
        displayName: 'Episode 12',
        directory: 'downloads',
        headers: const {'Referer': 'https://example.com'},
        updates: Updates.statusAndProgress,
        allowPause: true,
        group: kLogicalDownloadGroup,
        metaData: 'episode:12',
      );
      final parallel = buildAdaptiveDownloadTask(template: normal, parts: 16);
      expect(parallel, isA<ParallelDownloadTask>());
      expect(parallel.taskId, normal.taskId);
      expect(parallel.filename, normal.filename);
      expect(parallel.metaData, normal.metaData);
      expect(parallel.group, kLogicalDownloadGroup);
      expect(downloadTaskPartCount(parallel), 16);
    });

    test('persistent child metadata resolves only its logical parent', () {
      final child = DownloadTask(
        taskId: 'episode.part.0',
        url: 'https://cdn.test/video',
        group: kPersistentDownloadChunkGroup,
        metaData: '{"parentTaskId":"episode"}',
      );
      final malformed = child.copyWith(metaData: 'not-json');
      final logical = DownloadTask(
        taskId: 'episode',
        url: 'https://cdn.test/video',
        group: kLogicalDownloadGroup,
        metaData: '{"parentTaskId":"wrong"}',
      );

      expect(downloadInternalParentTaskId(child), 'episode');
      expect(downloadInternalParentTaskId(malformed), isNull);
      expect(downloadInternalParentTaskId(logical), isNull);
    });

    test('internal chunks are never logical episode tasks', () {
      final child = DownloadTask(
        url: 'https://example.com/episode.mp4',
        group: FileDownloader.chunkGroup,
      );
      final parent = ParallelDownloadTask(
        url: 'https://example.com/episode.mp4',
        chunks: 16,
      );
      expect(isInternalDownloaderChunk(child), isTrue);
      expect(isLogicalEpisodeDownloadTask(child), isFalse);
      expect(kPersistentDownloadChunkGroup, isNot(kLogicalDownloadGroup));
      expect(isLogicalEpisodeDownloadTask(parent), isTrue);
    });
  });
}

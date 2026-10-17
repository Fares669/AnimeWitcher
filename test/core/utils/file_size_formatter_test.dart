import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/utils/file_size_formatter.dart';

void main() {
  test('page counts use localized units and honest unknown totals', () {
    expect(formatDownloadPageCount(completedPages: 12, totalPages: 23, pageLabel: 'صفحة'), '12/23 صفحة');
    expect(formatDownloadPageCount(completedPages: 5, totalPages: null, pageLabel: 'pages'), '5/? pages');
    expect(formatDownloadPageCount(completedPages: -2, totalPages: null, pageLabel: 'pages'), '0/? pages');
    expect(formatDownloadPageCount(completedPages: null, totalPages: null, pageLabel: 'pages'), '0/? pages');
    expect(formatDownloadPageCount(completedPages: 24, totalPages: 23, pageLabel: 'pages'), '23/23 pages');
  });

  group('formatFileSize', () {
    test('uses decimal megabytes like iOS ByteCountFormatter', () {
      expect(formatFileSize(542900000, fractionDigits: 1), '542.9 MB');
    });

    test('uses decimal gigabytes', () {
      expect(formatFileSize(1500000000, fractionDigits: 1), '1.5 GB');
    });
  });

  group('formatDownloadSizePair', () {
    test('matches the values shown by the iOS download task', () {
      expect(
        formatDownloadSizePair(totalBytes: 542900000, progress: 72.7 / 542.9),
        '72.7 MB / 542.9 MB',
      );
    });

    test('clamps invalid progress values', () {
      expect(
        formatDownloadSizePair(totalBytes: 500000000, progress: 2),
        '500.0 MB / 500.0 MB',
      );
    });

    test('uses a placeholder while the total size is unknown', () {
      expect(
        formatDownloadSizePair(totalBytes: -1, progress: 0.5),
        '-- / -- MB',
      );
    });
  });
}

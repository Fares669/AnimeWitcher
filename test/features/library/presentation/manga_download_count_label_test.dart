import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/library/presentation/download_unit_count_label.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Arabic manga count uses فصل فصلان فصول', () {
    expect(
      completedDownloadUnitCountLabel(
        kind: DownloadMediaKind.mangaChapter,
        count: 1,
        isArabic: true,
      ),
      'فصل',
    );
    expect(
      completedDownloadUnitCountLabel(
        kind: DownloadMediaKind.mangaChapter,
        count: 2,
        isArabic: true,
      ),
      'فصلان',
    );
    expect(
      completedDownloadUnitCountLabel(
        kind: DownloadMediaKind.mangaChapter,
        count: 3,
        isArabic: true,
      ),
      '3 فصول',
    );
  });

  test('video count preserves episode copy', () {
    expect(
      completedDownloadUnitCountLabel(
        kind: DownloadMediaKind.videoEpisode,
        count: 2,
        isArabic: true,
      ),
      'حلقتان',
    );
  });
}

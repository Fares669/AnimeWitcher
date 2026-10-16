import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/library/presentation/download_unit_count_label.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const arabicForms = {
    DownloadMediaKind.videoEpisode: {
      0: '0 حلقة',
      1: 'حلقة',
      2: 'حلقتان',
      3: '3 حلقات',
      10: '10 حلقات',
      11: '11 حلقة',
      21: '21 حلقة',
      100: '100 حلقة',
      103: '103 حلقات',
    },
    DownloadMediaKind.mangaChapter: {
      0: '0 فصل',
      1: 'فصل',
      2: 'فصلان',
      3: '3 فصول',
      10: '10 فصول',
      11: '11 فصل',
      21: '21 فصل',
      100: '100 فصل',
      103: '103 فصول',
    },
  };
  for (final media in arabicForms.entries) {
    for (final form in media.value.entries) {
      test(
        '${media.key} localizes ${form.key} without reversing source text',
        () {
          expect(
            completedDownloadUnitCountLabel(kind: media.key, count: form.key),
            form.value,
          );
        },
      );
    }
  }
}

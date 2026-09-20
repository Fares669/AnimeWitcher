import 'package:animewitcher/l10n/generated/app_localizations_ar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsAr();

  test('manga feature strings are localized in Arabic', () {
    expect(l10n.manga, 'مانجا');
    expect(l10n.manhwa, 'مانهوا');
    expect(l10n.chapters, 'الفصول');
    expect(l10n.latestChapters, 'أحدث الفصول');
    expect(l10n.mangaDetails, 'التفاصيل');
    expect(l10n.mangaNoChapters, 'لا توجد فصول');
    expect(l10n.mangaNoPages, 'لا توجد صفحات');
    expect(l10n.mangaDownloadChapter, 'تنزيل الفصل');
    expect(l10n.mangaDeleteChapter, 'حذف الفصل');
    expect(l10n.searchDomainCharacters, 'شخصيات');
  });

  test('manga chapter count keeps Arabic singular dual plural', () {
    expect(l10n.mangaChapterCount(1), 'فصل');
    expect(l10n.mangaChapterCount(2), 'فصلان');
    expect(l10n.mangaChapterCount(3), '3 فصول');
  });

  test('manga library strings use reading semantics', () {
    expect(l10n.mangaReadingNow, 'أقرأها حالياً');
    expect(l10n.mangaPlanToRead, 'أرغب بقراءتها');
    expect(l10n.mangaCompletedReading, 'تمت قراءتها');
  });
}

import '../../../core/services/download_v2/download_v2_models.dart';

String completedDownloadUnitCountLabel({
  required DownloadMediaKind kind,
  required int count,
  required bool isArabic,
}) {
  if (kind == DownloadMediaKind.mangaChapter) {
    if (!isArabic) return count == 1 ? '1 chapter' : '$count chapters';
    if (count == 1) return 'فصل';
    if (count == 2) return 'فصلان';
    return '$count فصول';
  }

  if (!isArabic) return count == 1 ? '1 episode' : '$count episodes';
  if (count == 1) return 'حلقة';
  if (count == 2) return 'حلقتان';
  return '$count حلقات';
}

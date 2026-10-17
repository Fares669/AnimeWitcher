import '../../../core/services/download_v2/download_v2_models.dart';

String completedDownloadUnitCountLabel({
  required DownloadMediaKind kind,
  required int count,
}) {
  final few = count % 100 >= 3 && count % 100 <= 10;
  if (kind == DownloadMediaKind.mangaChapter) {
    if (count == 1) return 'فصل';
    if (count == 2) return 'فصلان';
    return few ? '$count فصول' : '$count فصل';
  }

  if (count == 1) return 'حلقة';
  if (count == 2) return 'حلقتان';
  return few ? '$count حلقات' : '$count حلقة';
}

/// Arabic relative time matching AnimeWitcher's catalog cards
/// (`منذ ساعتين`, `منذ 12 ساعة`).
String formatArabicRelativeTime(DateTime? date, {DateTime? now}) {
  if (date == null) return '';
  final elapsed = (now ?? DateTime.now()).difference(date);
  final safe = elapsed.isNegative ? Duration.zero : elapsed;

  if (safe.inMinutes < 1) return 'الآن';
  if (safe.inHours < 1) {
    return _arabicUnits(safe.inMinutes, 'دقيقة', 'دقيقتين', 'دقائق');
  }
  if (safe.inDays < 1) {
    return _arabicUnits(safe.inHours, 'ساعة', 'ساعتين', 'ساعات');
  }
  if (safe.inDays >= 30) {
    final local = date.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year}';
  }
  return _arabicUnits(safe.inDays, 'يوم', 'يومين', 'أيام');
}

String _arabicUnits(int count, String singular, String dual, String plural) {
  if (count == 1) return 'منذ $singular';
  if (count == 2) return 'منذ $dual';
  if (count >= 3 && count <= 10) return 'منذ $count $plural';
  return 'منذ $count $singular';
}

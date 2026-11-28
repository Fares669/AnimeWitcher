import '../../../../core/domain/entity/manga.dart';
import '../../../../core/utils/digit_normalization.dart';

/// Which chapters the list shows.
enum MangaChapterFilter { all, unread, downloaded }

/// How many chapters one range of the range menu holds.
const int mangaChapterRangeSize = 50;

/// The chapters in reading order, lowest number first. A source that leaves
/// any chapter without a number keeps its own order, reversed when it lists
/// the newest first.
List<MangaChapter> mangaChaptersInReadingOrder(List<MangaChapter> chapters) {
  final ordered = List<MangaChapter>.of(chapters);
  if (ordered.every((chapter) => chapter.number != null)) {
    ordered.sort((a, b) => a.number!.compareTo(b.number!));
    return ordered;
  }
  final first = ordered.isEmpty ? null : ordered.first.number;
  final last = ordered.isEmpty ? null : ordered.last.number;
  if (first != null && last != null && first > last) {
    return ordered.reversed.toList(growable: false);
  }
  return ordered;
}

/// The range menu's groups: consecutive runs of [size] in reading order.
List<List<MangaChapter>> mangaChapterRanges(
  List<MangaChapter> chapters, {
  int size = mangaChapterRangeSize,
}) {
  final ordered = mangaChaptersInReadingOrder(chapters);
  return <List<MangaChapter>>[
    for (var i = 0; i < ordered.length; i += size)
      ordered.sublist(i, (i + size).clamp(0, ordered.length)),
  ];
}

String _number(double value) => value == value.truncateToDouble()
    ? value.toInt().toString()
    : value.toString();

/// "51–100" for a range: its first and last chapter numbers, or its
/// positions when the source numbers none.
String mangaChapterRangeLabel(List<MangaChapter> range, int rangeIndex) {
  final first = range.first.number, last = range.last.number;
  if (first != null && last != null) {
    return first == last
        ? _number(first)
        : '${_number(first)}–${_number(last)}';
  }
  final start = rangeIndex * mangaChapterRangeSize + 1;
  return '$start–${start + range.length - 1}';
}

/// The chapter a typed number means: that chapter, else the first after it
/// (a source can skip numbers), else none when it is past the last.
MangaChapter? mangaChapterForNumber(List<MangaChapter> chapters, double n) {
  for (final chapter in mangaChaptersInReadingOrder(chapters)) {
    final number = chapter.number;
    if (number != null && number >= n) return chapter;
  }
  return null;
}

/// Whether [chapter] answers [query], the way the anime episode search
/// does: a number keeps the chapters whose number starts with it — "1" keeps
/// 1, 10 to 19 and 100 up — and words search the chapter's name.
bool mangaChapterMatchesQuery(MangaChapter chapter, String query) =>
    mangaChapterMatcher(query)(chapter);

final _numericQuery = RegExp(r'^\d+(\.\d*)?$');
final _numberInTitle = RegExp(r'\d+(\.\d+)?');

/// Prepare once when filtering a list, not once for every chapter in it.
bool Function(MangaChapter) mangaChapterMatcher(String query) {
  final needle = normalizeLocalizedDigits(query).trim().replaceAll(',', '.');
  if (needle.isEmpty) return (_) => true;
  if (_numericQuery.hasMatch(needle)) {
    return (chapter) {
      final number = chapter.number;
      final label = number == null
          ? _numberInTitle
                .firstMatch(normalizeLocalizedDigits(chapter.name))
                ?.group(0)
          : _number(number);
      return label != null && label.startsWith(needle);
    };
  }
  final text = needle.toLowerCase();
  return (chapter) => chapter.name.toLowerCase().contains(text);
}

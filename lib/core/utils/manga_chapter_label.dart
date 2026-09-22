import '../domain/entity/manga.dart';

/// Keeps source chapter titles intact and fills in the label for bare numbers.
String mangaChapterDisplayName(MangaChapter chapter) {
  final name = chapter.name.trim();
  if (name.isEmpty) {
    return chapter.number == null
        ? 'الفصل'
        : 'الفصل ${_formatChapterNumber(chapter.number!)}';
  }
  if (name.contains('الفصل') ||
      RegExp(r'^\s*(?:chapter|ch)\b', caseSensitive: false).hasMatch(name)) {
    return name;
  }

  final number = RegExp(r'^\s*\d+(?:[.,]\d+)?').firstMatch(name);
  if (number == null) return 'الفصل $name';

  final label = number.group(0)!.trim();
  final suffix = name.substring(number.end).trim();
  return 'الفصل $label${suffix.isEmpty ? '' : ' $suffix'}';
}

String _formatChapterNumber(double number) =>
    number == number.truncateToDouble()
        ? number.toInt().toString()
        : number.toString();

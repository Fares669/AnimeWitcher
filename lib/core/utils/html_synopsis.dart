import 'package:html/dom.dart' as dom;

/// Extracts a single HTML element's text while preserving `<br>` line breaks
/// and collapsing redundant whitespace within each line.
String? extractHtmlParagraphText(dom.Element? element) {
  if (element == null) return null;
  final clone = element.clone(true);
  for (final br in clone.querySelectorAll('br')) {
    br.replaceWith(dom.Text('\n'));
  }
  final lines = clone.text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (lines.isEmpty) return null;
  return lines.join('\n');
}

/// Joins non-empty paragraph elements into a multi-paragraph synopsis string.
String? joinHtmlParagraphs(Iterable<dom.Element> elements) {
  final parts = elements
      .map(extractHtmlParagraphText)
      .whereType<String>()
      .toList(growable: false);
  if (parts.isEmpty) return null;
  return parts.join('\n\n');
}

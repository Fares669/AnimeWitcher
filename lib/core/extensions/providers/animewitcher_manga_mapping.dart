import 'package:html_unescape/html_unescape.dart';

import '../../domain/entity/manga.dart';
import '../../domain/entity/multimedia_item.dart';

final _htmlUnescape = HtmlUnescape();

String _text(Object? value) {
  if (value is Map) {
    final map = _map(value);
    for (final key in const <String>['ar', 'arabic', 'en', 'english', 'value']) {
      final nested = map[key];
      final text = nested?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }
  return value?.toString().trim() ?? '';
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return <String, Object?>{
    for (final entry in value.entries) entry.key.toString(): entry.value,
  };
}

List<Object?> _list(Object? value) =>
    value is List ? List<Object?>.from(value) : const <Object?>[];

String _stripHtml(Object? value) {
  final text = _htmlUnescape.convert(_text(value));
  return text.replaceAll(RegExp(r'<[^>]+>'), '').trim();
}

String _firstText(Map<String, Object?> source, Iterable<String> keys) {
  for (final key in keys) {
    final value = _text(source[key]);
    if (value.isNotEmpty) return value;
  }
  return '';
}

String _posterUrl(Map<String, Object?> source) {
  final poster = source['poster'];
  if (poster is Map) {
    final map = _map(poster);
    final nested = _firstText(map, const <String>[
      'large',
      'medium',
      'small',
      'url',
      'uri',
    ]);
    if (nested.isNotEmpty) return nested;
  }
  return _firstText(source, const <String>[
    'poster_uri',
    'posterUrl',
    'poster_url',
    'cover_uri',
    'coverUrl',
  ]);
}

int? _year(Map<String, Object?> source) {
  final details = _map(source['details']);
  final candidates = <Object?>[
    details['year'],
    details['release_year'],
    source['year'],
  ];
  for (final value in candidates) {
    final parsed = int.tryParse(_text(value));
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
}

ShowStatus _status(Map<String, Object?> source) {
  final details = _map(source['details']);
  final value = _firstText(
    <String, Object?>{
      'detailsState': details['state'] ?? details['status'],
      ...source,
    },
    const <String>['detailsState', 'statictes', 'status', 'state'],
  ).toLowerCase();

  if (value.contains('مكتمل') ||
      value.contains('منتهي') ||
      value.contains('complete') ||
      value.contains('finished')) {
    return ShowStatus.completed;
  }
  if (value.contains('قادم') ||
      value.contains('لم يبدأ') ||
      value.contains('upcoming')) {
    return ShowStatus.upcoming;
  }
  return ShowStatus.ongoing;
}

List<String>? _tags(Map<String, Object?> source) {
  final raw = _list(source['tags']);
  final tags = <String>[];
  for (final value in raw) {
    final tag = _text(value);
    if (tag.isNotEmpty && !tags.contains(tag)) tags.add(tag);
  }
  return tags.isEmpty ? null : tags;
}

String _stableMangaId(Map<String, Object?> source) {
  return _firstText(source, const <String>[
    'objectID',
    'manga_id',
    'mangaId',
    'id',
    'path',
  ]);
}

String? _optional(String value) => value.isEmpty ? null : value;

/// Maps the live AnimeWitcher Manga Algolia/Firestore shape.
///
/// Manga remains a [MultimediaItem] at the catalog boundary so existing
/// poster grids can be reused, but chapters are deliberately not represented
/// as [Episode] values.
MultimediaItem mapAnimeWitcherMangaHit(Map<String, Object?> source) {
  final id = _stableMangaId(source);
  final details = _map(source['details']);
  final title = _firstText(source, const <String>['name', 'manga_name', 'title']);
  final type = _firstText(source, const <String>['type', 'manga_type']);
  final englishTitle = _firstText(
    <String, Object?>{
      ...details,
      ...source,
    },
    const <String>[
      'english_title',
      'englishTitle',
      'name_english',
      'manga_name_english',
    ],
  );
  final mangalekPageUrl = _firstText(source, const <String>[
    'mangalek_page_url',
    'mangalekPageUrl',
  ]);
  final malId = _firstText(source, const <String>['mal_id', 'malId']);
  final anilistId = _firstText(source, const <String>[
    'aniList_id',
    'anilist_id',
    'anilistId',
  ]);

  return MultimediaItem(
    title: title,
    url: 'https://animewitcher.com/manga/' + Uri.encodeComponent(id),
    posterUrl: _posterUrl(source),
    description: _optional(
      _stripHtml(source['story'] ?? source['story_ar'] ?? details['story']),
    ),
    contentType: MultimediaContentType.manga,
    provider: 'com.fares669.animewitcher.native',
    year: _year(source),
    status: _status(source),
    tags: _tags(source),
    catalogType: _optional(type),
    syncData: <String, String>{
      if (id.isNotEmpty) 'mangaId': id,
      if (mangalekPageUrl.isNotEmpty) 'mangalekPageUrl': mangalekPageUrl,
      if (malId.isNotEmpty) 'malId': malId,
      if (anilistId.isNotEmpty) 'anilistId': anilistId,
      if (englishTitle.isNotEmpty) 'englishTitle': englishTitle,
    },
  );
}

String _attribute(String tag, String name) {
  final pattern = RegExp(
    RegExp.escape(name) + r"""\s*=\s*["']([^"']*)["']""",
    caseSensitive: false,
    dotAll: true,
  );
  return pattern.firstMatch(tag)?.group(1)?.trim() ?? '';
}

double? _chapterNumber(String label, String url) {
  final labelMatch = RegExp(r'\d+(?:[.,]\d+)?').firstMatch(label);
  final raw = labelMatch?.group(0)?.replaceAll(',', '.');
  final fromLabel = raw == null ? null : double.tryParse(raw);
  if (fromLabel != null) return fromLabel;

  final urlMatch = RegExp(
    r'(?:chapter|ch)[-_]?(\d+(?:[-_.]\d+)?)',
    caseSensitive: false,
  ).firstMatch(url);
  final fromUrl = urlMatch?.group(1)?.replaceAll(RegExp(r'[-_]'), '.');
  return fromUrl == null ? null : double.tryParse(fromUrl);
}

DateTime? _publishedAt(String block) {
  final dateBlock = RegExp(
    r"""class\s*=\s*["'][^"']*chapter-release-date[^"']*["'][^>]*>(.*?)<""",
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(block);
  final raw = _stripHtml(dateBlock?.group(1));
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

String _chapterId(String url, String name) {
  final uri = Uri.tryParse(url);
  if (uri != null) {
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (segments.isNotEmpty) return segments.last;
  }
  return Uri.encodeComponent(name);
}

/// Parses MangaLek/Mangalik chapter rows referenced by AnimeWitcher.
///
/// The parser intentionally keys off `wp-manga-chapter` instead of every
/// anchor so unrelated navigation links never become chapters.
List<MangaChapter> parseMangaLekChapters({
  required String html,
  required String mangaId,
  required String documentUrl,
}) {
  final base = Uri.tryParse(documentUrl);
  if (base == null) return const <MangaChapter>[];

  final rows = RegExp(
    r"""<li\b[^>]*class\s*=\s*["'][^"']*wp-manga-chapter[^"']*["'][^>]*>(.*?)</li>""",
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html);

  final chapters = <MangaChapter>[];
  final seen = <String>{};
  for (final row in rows) {
    final block = row.group(1) ?? '';
    final anchor = RegExp(
      r'<a\b([^>]*)>(.*?)</a>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(block);
    if (anchor == null) continue;

    final href = _attribute(anchor.group(1) ?? '', 'href');
    if (href.isEmpty) continue;
    final url = base.resolve(href).toString();
    if (!seen.add(url)) continue;

    final name = _stripHtml(anchor.group(2));
    if (name.isEmpty) continue;
    chapters.add(
      MangaChapter(
        id: _chapterId(url, name),
        mangaId: mangaId,
        url: url,
        name: name,
        number: _chapterNumber(name, url),
        publishedAt: _publishedAt(block),
      ),
    );
  }
  return chapters;
}

/// Parses reader page images from MangaLek/Mangalik `page-break` blocks.
///
/// Page-specific headers stay attached to each page because many image CDNs
/// validate the chapter referer.
List<MangaPage> parseMangaLekPages({
  required String html,
  required String chapterUrl,
}) {
  final base = Uri.tryParse(chapterUrl);
  if (base == null) return const <MangaPage>[];

  final blocks = RegExp(
    r"""<div\b[^>]*class\s*=\s*["'][^"']*page-break[^"']*["'][^>]*>(.*?)</div>""",
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html);

  final pages = <MangaPage>[];
  final seen = <String>{};
  for (final block in blocks) {
    final image = RegExp(
      r'<img\b([^>]*)>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(block.group(1) ?? '');
    if (image == null) continue;

    final attrs = image.group(1) ?? '';
    final rawUrl = <String>[
      _attribute(attrs, 'data-src'),
      _attribute(attrs, 'data-lazy-src'),
      _attribute(attrs, 'src'),
    ].firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (rawUrl.isEmpty) continue;

    final imageUrl = base.resolve(_htmlUnescape.convert(rawUrl)).toString();
    if (!seen.add(imageUrl)) continue;
    pages.add(
      MangaPage(
        index: pages.length,
        imageUrl: imageUrl,
        headers: <String, String>{'Referer': chapterUrl},
      ),
    );
  }
  return pages;
}

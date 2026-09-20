import 'multimedia_item.dart';

/// One chapter in an AnimeWitcher Manga/Manhwa title.
///
/// [number] is optional and intentionally a [double]: AnimeWitcher can expose
/// decimal chapters (for example 12.5) and non-numeric specials.
final class MangaChapter {
  const MangaChapter({
    required this.id,
    required this.mangaId,
    required this.url,
    required this.name,
    this.number,
    this.publishedAt,
  });

  final String id;
  final String mangaId;
  final String url;
  final String name;
  final double? number;
  final DateTime? publishedAt;
}

/// One ordered image page in a Manga/Manhwa chapter.
final class MangaPage {
  const MangaPage({
    required this.index,
    required this.imageUrl,
    this.headers = const <String, String>{},
  });

  final int index;
  final String imageUrl;
  final Map<String, String> headers;
}

/// Home/search projection for a Manga title and its latest chapter.
final class MangaLatestChapter {
  const MangaLatestChapter({
    required this.manga,
    required this.chapter,
  });

  final MultimediaItem manga;
  final MangaChapter chapter;
}

/// Pagination wrapper for latest Manga/Manhwa chapter rows.
final class MangaLatestChapterPage {
  const MangaLatestChapterPage({
    required this.items,
    required this.nextOffset,
    required this.hasMore,
  });

  final List<MangaLatestChapter> items;
  final int nextOffset;
  final bool hasMore;
}

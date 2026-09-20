import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item(String title, MultimediaContentType type) => MultimediaItem(
  title: title,
  url: 'https://example.test/' + title,
  posterUrl: '',
  contentType: type,
);

void main() {
  test('library media kinds keep manga separate from anime/video titles', () {
    final items = <MultimediaItem>[
      _item('Anime', MultimediaContentType.anime),
      _item('Movie', MultimediaContentType.movie),
      _item('Manga', MultimediaContentType.manga),
    ];

    expect(
      filterLibraryItemsByKind(items, LibraryMediaKind.anime)
          .map((item) => item.title),
      <String>['Anime', 'Movie'],
    );
    expect(
      filterLibraryItemsByKind(items, LibraryMediaKind.manga)
          .map((item) => item.title),
      <String>['Manga'],
    );
  });

  test('library defaults to anime', () {
    expect(
      LibraryMediaKind.fromStorageKey(null),
      LibraryMediaKind.anime,
    );
    expect(
      LibraryMediaKind.fromStorageKey('unknown'),
      LibraryMediaKind.anime,
    );
  });
}

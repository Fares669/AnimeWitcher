import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/features/library/presentation/library_lists.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item(String title, MultimediaContentType type) =>
    MultimediaItem(title: title, url: title, posterUrl: '', contentType: type);

void main() {
  test('shelf search requires every word and preserves shelf order', () {
    final items = [
      _item('One Piece Film: Red', MultimediaContentType.movie),
      _item('Red Garden', MultimediaContentType.anime),
      _item('One Piece RED إصدار', MultimediaContentType.manga),
    ];

    expect(filterLibraryTitles(items, '  REd\tPiEcE  '), [items[0], items[2]]);
    expect(filterLibraryTitles(items, 'إصد piece'), [items[2]]);
    expect(filterLibraryTitles(items, '   '), items);
  });

  test(
    'the recent tab counts only watchable items and never changes history',
    () {
      final types = [
        MultimediaContentType.movie,
        MultimediaContentType.manga,
        MultimediaContentType.anime,
      ];
      final history = [
        for (var i = 0; i < types.length; i++)
          HistoryItem(
            item: _item(types[i].name, types[i]),
            timestamp: i,
            position: 0,
            duration: 0,
          ),
      ];

      expect(libraryRecentEntries(history, LibraryMediaKind.anime).length, 2);
      expect(libraryRecentEntries(history, LibraryMediaKind.manga), isEmpty);
      expect(history.map((entry) => entry.item.contentType), types);
    },
  );
}

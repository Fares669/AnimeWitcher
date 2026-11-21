import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/library_category.dart';

MultimediaItem _item({
  ShowStatus status = ShowStatus.ongoing,
  Map<String, String>? syncData,
}) {
  return MultimediaItem(
    title: 'Kagurabachi',
    url: 'anime://kagurabachi',
    posterUrl: 'https://images.example/poster.jpg',
    status: status,
    syncData: syncData,
  );
}

void main() {
  test('legacy on-hold values map to Continue Later', () {
    expect(
      LibraryCategory.fromStorageKey('on_Hold'),
      LibraryCategory.continueLater,
    );
    expect(
      LibraryCategory.fromStorageKey('onHold'),
      LibraryCategory.continueLater,
    );
  });

  test('Favorites is independent from primary list categories', () {
    expect(LibraryCategory.favorite.isPrimary, isFalse);
    expect(
      LibraryCategory.primaryValues,
      containsAll(<LibraryCategory>[
        LibraryCategory.watching,
        LibraryCategory.continueLater,
        LibraryCategory.planToWatch,
        LibraryCategory.completed,
        LibraryCategory.notInterested,
      ]),
    );
    expect(
      LibraryCategory.primaryValues,
      isNot(contains(LibraryCategory.favorite)),
    );
  });

  group('assignmentValuesFor unaired titles', () {
    test('hides watching when details.state is لم يتم بثه بعد', () {
      final item = _item(
        status: ShowStatus.ongoing,
        syncData: const <String, String>{'awState': kNotYetAiredArabicState},
      );

      expect(item.isNotYetAired, isTrue);
      expect(LibraryCategory.assignmentValuesFor(item), <LibraryCategory>[
        LibraryCategory.continueLater,
        LibraryCategory.planToWatch,
        LibraryCategory.notInterested,
      ]);
    });

    test('hides watching when awState is missing and status is upcoming', () {
      final item = _item(status: ShowStatus.upcoming);

      expect(item.isNotYetAired, isTrue);
      expect(
        LibraryCategory.assignmentValuesFor(item),
        isNot(contains(LibraryCategory.watching)),
      );
      expect(
        LibraryCategory.assignmentValuesFor(item),
        containsAll(<LibraryCategory>[
          LibraryCategory.continueLater,
          LibraryCategory.planToWatch,
          LibraryCategory.notInterested,
        ]),
      );
    });

    test(
      'still hides watching if the title is already on the watching list',
      () {
        final item = _item(
          status: ShowStatus.upcoming,
          syncData: const <String, String>{'awState': kNotYetAiredArabicState},
        );

        expect(LibraryCategory.watching.isAssignableTo(item), isFalse);
        expect(
          LibraryCategory.assignmentValuesFor(item),
          isNot(contains(LibraryCategory.watching)),
        );
      },
    );

    test('keeps watching for an airing title', () {
      final item = _item(
        status: ShowStatus.ongoing,
        syncData: const <String, String>{'awState': 'مستمر'},
      );

      expect(item.isNotYetAired, isFalse);
      expect(
        LibraryCategory.assignmentValuesFor(item),
        contains(LibraryCategory.watching),
      );
    });

    test('treats blank awState as missing and uses ShowStatus', () {
      final blank = _item(
        status: ShowStatus.upcoming,
        syncData: const <String, String>{'awState': '  '},
      );
      final serializedNull = _item(
        status: ShowStatus.upcoming,
        syncData: const <String, String>{'awState': 'null'},
      );

      expect(blank.isNotYetAired, isTrue);
      expect(serializedNull.isNotYetAired, isTrue);
    });

    test('does not treat a different details.state as unaired', () {
      final item = _item(
        status: ShowStatus.upcoming,
        syncData: const <String, String>{'awState': 'مستمر'},
      );

      expect(item.isNotYetAired, isFalse);
      expect(
        LibraryCategory.assignmentValuesFor(item),
        contains(LibraryCategory.watching),
      );
    });
  });

  test('hides completed unless the title is finished', () {
    final ongoing = _item(status: ShowStatus.ongoing);
    final completed = _item(status: ShowStatus.completed);

    expect(
      LibraryCategory.assignmentValuesFor(ongoing),
      isNot(contains(LibraryCategory.completed)),
    );
    expect(
      LibraryCategory.assignmentValuesFor(completed),
      contains(LibraryCategory.completed),
    );
  });

  test('hides AnimeWitcher-only lists for Witanime anime titles', () {
    final witanimeAnime = MultimediaItem(
      title: 'Frieren',
      url: 'https://witanime.site/anime/frieren',
      posterUrl: '',
      provider: 'witanime',
      status: ShowStatus.completed,
    );
    expect(
      LibraryCategory.assignmentValuesFor(witanimeAnime),
      <LibraryCategory>[
        LibraryCategory.watching,
        LibraryCategory.planToWatch,
        LibraryCategory.completed,
      ],
    );
    expect(
      LibraryCategory.valuesForCatalog(witanimeAnime: true),
      <LibraryCategory>[
        LibraryCategory.favorite,
        LibraryCategory.watching,
        LibraryCategory.planToWatch,
        LibraryCategory.completed,
      ],
    );
  });
}

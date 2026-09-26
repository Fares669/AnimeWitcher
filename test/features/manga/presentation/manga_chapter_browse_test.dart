import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/presentation/widgets/manga_chapter_browse.dart';
import 'package:animewitcher/features/manga/presentation/widgets/manga_chapter_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Storage extends StorageService {
  final Map<String, String> values = <String, String>{};
  final Map<String, Object?> playerSettings = <String, Object?>{};

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) =>
      (playerSettings[key] ?? defaultValue) as T?;

  @override
  Future<void> setPlayerSetting(String key, dynamic value) async {
    playerSettings[key] = value;
  }
}

MangaChapter _chapter(int n) => MangaChapter(
  id: 'c$n',
  mangaId: 'm1',
  url: 'https://example.test/c$n',
  name: 'Chapter $n',
  number: n.toDouble(),
);

/// Newest first, the way sources tend to list them.
final List<MangaChapter> _many = <MangaChapter>[
  for (var n = 120; n >= 1; n--) _chapter(n),
];

Future<MangaReadingRepository> _readUpTo(int last) async {
  final repository = MangaReadingRepository(_Storage());
  await repository.setReadStates('m1', <String>[
    for (var n = 1; n <= last; n++) 'c$n',
  ], read: true);
  return repository;
}

Widget _app(MangaReadingRepository repository) => ProviderScope(
  overrides: [
    storageServiceProvider.overrideWithValue(_Storage()),
    mangaReadingRepositoryProvider.overrideWithValue(repository),
  ],
  child: MaterialApp(
    home: Scaffold(body: MangaChapterList(chapters: _many)),
  ),
);

void main() {
  group('ranges and go-to', () {
    test('ranges run in reading order, fifty at a time', () {
      final ranges = mangaChapterRanges(_many);
      expect(ranges, hasLength(3));
      expect(mangaChapterRangeLabel(ranges[0], 0), '1–50');
      expect(mangaChapterRangeLabel(ranges[2], 2), '101–120');
    });

    test('a typed number finds that chapter, or the next one there is', () {
      final gappy = <MangaChapter>[_chapter(1), _chapter(2), _chapter(5)];
      expect(mangaChapterForNumber(gappy, 2)?.id, 'c2');
      expect(mangaChapterForNumber(gappy, 3)?.id, 'c5');
      expect(mangaChapterForNumber(gappy, 9), isNull);
    });

    test('a list without numbers keeps its own order', () {
      const unnumbered = <MangaChapter>[
        MangaChapter(id: 'a', mangaId: 'm1', url: 'a', name: 'Prologue'),
        MangaChapter(id: 'b', mangaId: 'm1', url: 'b', name: 'Extra'),
      ];
      expect(mangaChaptersInReadingOrder(unnumbered).map((c) => c.id), [
        'a',
        'b',
      ]);
    });
  });

  group('chapter list tools', () {
    testWidgets('opens on every chapter, with the range menu on all', (
      tester,
    ) async {
      await tester.pumpWidget(_app(await _readUpTo(0)));

      expect(find.text('All chapters'), findsOneWidget);
      expect(find.text('Chapter 120'), findsOneWidget);
    });

    testWidgets('a range narrows the list to its fifty', (tester) async {
      await tester.pumpWidget(_app(await _readUpTo(0)));

      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapter-range-menu')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chapters 51–100').last);
      await tester.pumpAndSettle();

      expect(find.text('Chapters 51–100'), findsOneWidget);
      expect(find.text('Chapter 120'), findsNothing);
      expect(find.text('Chapter 100'), findsOneWidget);
    });

    testWidgets('search keeps only the chapters it matches', (tester) async {
      await tester.pumpWidget(_app(await _readUpTo(0)));

      await tester.enterText(
        find.byKey(const ValueKey<String>('manga-chapter-go-to')),
        '7',
      );
      await tester.pumpAndSettle();

      // As the anime episode search: 7, and 70 to 79, and nothing else.
      expect(find.text('Chapter 79'), findsOneWidget);
      expect(find.text('Chapter 80'), findsNothing);
      expect(find.text('Chapter 120'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey<String>('manga-chapter-go-to')),
        '120',
      );
      await tester.pumpAndSettle();
      expect(find.text('Chapter 120'), findsOneWidget);
      expect(find.text('Chapter 79'), findsNothing);
      expect(find.text('Chapter 12'), findsNothing);
    });

    testWidgets('a search with no chapter says so', (tester) async {
      await tester.pumpWidget(_app(await _readUpTo(0)));

      await tester.enterText(
        find.byKey(const ValueKey<String>('manga-chapter-go-to')),
        '999',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('manga-chapter-filter-empty')),
        findsOneWidget,
      );

      // Clearing it brings every chapter back.
      await tester.enterText(
        find.byKey(const ValueKey<String>('manga-chapter-go-to')),
        '',
      );
      await tester.pumpAndSettle();
      expect(find.text('Chapter 120'), findsOneWidget);
    });

    testWidgets('unread hides what has been read', (tester) async {
      await tester.pumpWidget(_app(await _readUpTo(119)));

      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapter-filter-unread')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Chapter 120'), findsOneWidget);
      expect(find.text('Chapter 119'), findsNothing);
    });

    testWidgets('downloaded with none shows a note, not a blank', (
      tester,
    ) async {
      await tester.pumpWidget(_app(await _readUpTo(0)));

      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapter-filter-downloaded')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('manga-chapter-filter-empty')),
        findsOneWidget,
      );
    });

    testWidgets('to current brings the next chapter back on screen', (
      tester,
    ) async {
      await tester.pumpWidget(_app(await _readUpTo(9)));

      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapter-to-current')),
      );
      await tester.pumpAndSettle();

      // Nine read: chapter 10 is next, far down a newest-first list.
      expect(find.text('Chapter 10'), findsOneWidget);
      expect(tester.getRect(find.text('Chapter 10')).top, lessThan(600));
    });
  });

  group('chapter search', () {
    MangaChapter chapter(double? number, String name) => MangaChapter(
      id: name,
      mangaId: 'm',
      url: 'c://$name',
      name: name,
      number: number,
    );

    test('a number keeps the chapters that start with it', () {
      expect(mangaChapterMatchesQuery(chapter(1, 'الفصل 1'), '1'), isTrue);
      expect(mangaChapterMatchesQuery(chapter(10, 'الفصل 10'), '1'), isTrue);
      expect(mangaChapterMatchesQuery(chapter(21, 'الفصل 21'), '1'), isFalse);
      expect(
        mangaChapterMatchesQuery(chapter(12.5, 'الفصل 12.5'), '12.'),
        isTrue,
      );
    });

    test('Arabic digits find the same chapter', () {
      expect(mangaChapterMatchesQuery(chapter(47, 'الفصل 47'), '٤٧'), isTrue);
    });

    test('a chapter with no number is found by the number in its name', () {
      expect(
        mangaChapterMatchesQuery(chapter(null, 'Chapter 305'), '30'),
        isTrue,
      );
    });

    test('words search the name', () {
      expect(
        mangaChapterMatchesQuery(
          chapter(3, 'الفصل 3 - الوقوع في الفخ'),
          'الفخ',
        ),
        isTrue,
      );
      expect(mangaChapterMatchesQuery(chapter(3, 'الفصل 3'), 'الفخ'), isFalse);
      expect(mangaChapterMatchesQuery(chapter(3, 'الفصل 3'), '  '), isTrue);
    });
  });
}

import 'dart:async';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_preloader.dart';
import 'package:flutter_test/flutter_test.dart';

List<MangaPage> _chapter(int count, [String name = 'chapter']) => [
  for (var index = 0; index < count; index++)
    MangaPage(index: index, imageUrl: 'https://example.test/$name/$index.jpg'),
];

Future<void> _yield() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a long chapter fetches only the nearby pages, not the visible ones',
    () async {
      final fetched = <int>[];
      final loader = MangaPagedPreloader(
        fetch: (page) async {
          fetched.add(page.index);
        },
      );
      addTearDown(loader.dispose);
      final chapter = _chapter(120);
      loader.update(chapter, firstVisible: 60, lastVisible: 61, distance: 3);
      await _yield();
      expect(fetched, [62, 59, 63, 58, 64, 57]);

      loader.update(chapter, firstVisible: 62, lastVisible: 63, distance: 3);
      await _yield();
      expect(fetched, [62, 59, 63, 58, 64, 57, 61, 65, 60, 66]);

      loader.update(chapter, firstVisible: 0, lastVisible: 0, distance: 0);
      await _yield();
      expect(fetched, hasLength(10));
    },
  );

  test(
    'rapid jumps replace queued work without overlapping transfers',
    () async {
      final requested = <String>[];
      final first = Completer<void>();
      final loader = MangaPagedPreloader(
        fetch: (page) async {
          requested.add(page.imageUrl);
          if (requested.length == 1) await first.future;
        },
      );
      addTearDown(loader.dispose);
      loader.update(
        _chapter(100, 'old'),
        firstVisible: 0,
        lastVisible: 0,
        distance: 12,
      );
      final current = _chapter(100, 'current');
      loader.update(current, firstVisible: 80, lastVisible: 80, distance: 2);
      loader.update(current, firstVisible: 90, lastVisible: 90, distance: 1);
      expect(requested, ['https://example.test/old/1.jpg']);
      first.complete();
      await _yield();
      expect(requested, [
        'https://example.test/old/1.jpg',
        'https://example.test/current/91.jpg',
        'https://example.test/current/89.jpg',
      ]);
    },
  );

  test(
    'local files do not hit network and disposal drops pending work',
    () async {
      final requested = <int>[];
      final blocked = Completer<void>();
      final loader = MangaPagedPreloader(
        fetch: (page) {
          requested.add(page.index);
          return blocked.future;
        },
      );
      final chapter = _chapter(8);
      chapter[1] = const MangaPage(index: 1, imageUrl: 'file:///offline/1.jpg');
      loader.update(chapter, firstVisible: 0, lastVisible: 0, distance: 5);
      expect(requested, [2]);
      loader.dispose();
      blocked.complete();
      await _yield();
      expect(requested, [2]);
    },
  );
}

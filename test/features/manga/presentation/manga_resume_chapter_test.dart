import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/features/manga/presentation/manga_resume_chapter.dart';
import 'package:flutter_test/flutter_test.dart';

MangaChapter _chapter(String id, double? number) => MangaChapter(
  id: id,
  mangaId: 'm1',
  url: 'chapter://$id',
  name: 'Chapter $id',
  number: number,
);

MangaReadingProgress _progress(String id, {bool read = false}) =>
    MangaReadingProgress(
      mangaId: 'm1',
      chapterId: id,
      pageIndex: 3,
      pageCount: 20,
      updatedAt: 1,
      isRead: read,
    );

void main() {
  // Listed newest first, the way sources often do.
  final chapters = <MangaChapter>[
    _chapter('3', 3),
    _chapter('2', 2),
    _chapter('1', 1),
  ];

  test('nothing read starts at the lowest chapter, not the first listed', () {
    final target = mangaResumeTarget(chapters, (_) => null);
    expect(target?.chapter.id, '1');
    expect(target?.kind, MangaResumeKind.start);
  });

  test('a chapter left part-way is picked up again', () {
    final progress = {'1': _progress('1', read: true), '2': _progress('2')};
    final target = mangaResumeTarget(chapters, (c) => progress[c.id]);
    expect(target?.chapter.id, '2');
    expect(target?.kind, MangaResumeKind.resume);
  });

  test('a finished chapter leads to the next one', () {
    final progress = {'2': _progress('2', read: true)};
    final target = mangaResumeTarget(chapters, (c) => progress[c.id]);
    expect(target?.chapter.id, '3');
    expect(target?.kind, MangaResumeKind.next);
  });

  test('with everything read the last chapter is offered again', () {
    final target = mangaResumeTarget(
      chapters,
      (c) => _progress(c.id, read: true),
    );
    expect(target?.chapter.id, '3');
    expect(target?.kind, MangaResumeKind.resume);
  });

  test('chapters without numbers keep the order the source gave', () {
    final unnumbered = <MangaChapter>[_chapter('a', null), _chapter('b', 2)];
    final target = mangaResumeTarget(unnumbered, (_) => null);
    expect(target?.chapter.id, 'a');
  });

  test('no chapters, nothing to read', () {
    expect(mangaResumeTarget(const <MangaChapter>[], (_) => null), isNull);
  });
}

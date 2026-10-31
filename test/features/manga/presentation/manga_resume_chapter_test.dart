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

MangaReadingProgress _progress(
  String id, {
  bool read = false,
  int pageIndex = 3,
}) => MangaReadingProgress(
  mangaId: 'm1',
  chapterId: id,
  pageIndex: pageIndex,
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

  test('an untouched earlier chapter is offered before later progress', () {
    final progress = {'2': _progress('2', read: true)};
    final target = mangaResumeTarget(chapters, (c) => progress[c.id]);
    expect(target?.chapter.id, '1');
    expect(target?.kind, MangaResumeKind.next);
  });

  test('the first unfinished chapter wins over a later part-read one', () {
    final progress = {'1': _progress('1', read: true), '3': _progress('3')};
    final target = mangaResumeTarget(chapters, (c) => progress[c.id]);
    expect(target?.chapter.id, '2');
    expect(target?.kind, MangaResumeKind.next);
  });

  test('marking every chapter unread points back at the first chapter', () {
    // Fully paged once, then marked unread: page counts are complete
    // but nothing counts as finished, so reading starts over.
    final target = mangaResumeTarget(
      chapters,
      (c) => _progress(c.id, pageIndex: 19),
    );
    expect(target?.chapter.id, '1');
    expect(target?.kind, MangaResumeKind.start);
  });

  test('with everything read the first chapter is offered to start over', () {
    final target = mangaResumeTarget(
      chapters,
      (c) => _progress(c.id, read: true),
    );
    expect(target?.chapter.id, '1');
    expect(target?.kind, MangaResumeKind.start);
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

import '../../../core/domain/entity/manga.dart';
import '../../../core/storage/manga_reading_repository.dart';

/// What the read button on a manga's page does next.
enum MangaResumeKind {
  /// Nothing finished yet: open the first chapter.
  start,

  /// A chapter was left part-way: go back to it.
  resume,

  /// Earlier chapters are finished: open the first one still to read.
  next,
}

final class MangaResumeTarget {
  const MangaResumeTarget(this.chapter, this.kind);

  final MangaChapter chapter;
  final MangaResumeKind kind;
}

/// Where reading picks up: the first chapter, in reading order, that is
/// not finished — a part-read chapter is picked up again, an untouched
/// one is next, and marking chapters unread moves the button back to
/// them. With every chapter finished it offers the first one again
/// rather than pointing back at the last chapter read.
///
/// Reading order is by chapter number, lowest first, so the answer does
/// not depend on the order the source lists them or the order the list
/// is shown. If any chapter has no number, the source's order is kept.
MangaResumeTarget? mangaResumeTarget(
  List<MangaChapter> chapters,
  MangaReadingProgress? Function(MangaChapter chapter) progressOf,
) {
  if (chapters.isEmpty) return null;
  final ordered = List<MangaChapter>.of(chapters);
  final numbered = ordered.every((chapter) => chapter.number != null);
  if (numbered) {
    ordered.sort((a, b) => a.number!.compareTo(b.number!));
  }

  final progresses = <MangaChapter, MangaReadingProgress?>{
    for (final chapter in ordered) chapter: progressOf(chapter),
  };
  final anyFinished = progresses.values.any(
    (progress) => progress != null && progress.isRead,
  );
  for (final chapter in ordered) {
    final progress = progresses[chapter];
    if (progress != null && progress.isRead) continue;
    if (progress != null &&
        progress.pagesRead > 0 &&
        progress.pagesRead < progress.pageCount) {
      return MangaResumeTarget(chapter, MangaResumeKind.resume);
    }
    return MangaResumeTarget(
      chapter,
      anyFinished ? MangaResumeKind.next : MangaResumeKind.start,
    );
  }
  return MangaResumeTarget(ordered.first, MangaResumeKind.start);
}

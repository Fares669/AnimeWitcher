import '../../../core/domain/entity/manga.dart';
import '../../../core/storage/manga_reading_repository.dart';

/// What the read button on a manga's page does next.
enum MangaResumeKind {
  /// Nothing read yet: open the first chapter.
  start,

  /// A chapter was left part-way: go back to it.
  resume,

  /// The last chapter reached was finished: open the one after it.
  next,
}

final class MangaResumeTarget {
  const MangaResumeTarget(this.chapter, this.kind);

  final MangaChapter chapter;
  final MangaResumeKind kind;
}

/// The chapter a reader is up to, in reading order.
///
/// Reading order is by chapter number, lowest first, so the answer does not
/// depend on the order the source lists them or the order the list is shown.
/// If any chapter has no number, the source's order is kept. The furthest
/// chapter with any progress decides: left unfinished, it is picked up
/// again; finished, the next one follows. With every chapter read the last
/// one is offered again rather than nothing.
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

  for (var i = ordered.length - 1; i >= 0; i--) {
    final progress = progressOf(ordered[i]);
    if (progress == null) continue;
    if (!progress.isRead) {
      return MangaResumeTarget(ordered[i], MangaResumeKind.resume);
    }
    if (i + 1 < ordered.length) {
      return MangaResumeTarget(ordered[i + 1], MangaResumeKind.next);
    }
    return MangaResumeTarget(ordered[i], MangaResumeKind.resume);
  }
  return MangaResumeTarget(ordered.first, MangaResumeKind.start);
}

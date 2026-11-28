import 'dart:math';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/manga/presentation/widgets/manga_chapter_download_index.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

MangaChapter _chapter(String mangaId, String id, String url) => MangaChapter(
  id: id,
  mangaId: mangaId,
  url: url,
  name: 'Chapter',
  number: 1,
);

DownloadItem _row(
  int offset, {
  TaskStatus status = TaskStatus.complete,
  DownloadMediaKind kind = DownloadMediaKind.mangaChapter,
  MangaChapter? chapter,
  String? logicalId,
  String? url,
}) => DownloadItem(
  task: DownloadTask(
    taskId: 'fixture-$offset',
    url: 'https://example.test/fixture',
    filename: 'fixture',
  ),
  status: status,
  progress: 0.5,
  item: MultimediaItem(
    title: 'Manga fixture',
    url: 'https://example.test/manga/fixture',
    posterUrl: '',
    contentType: MultimediaContentType.manga,
  ),
  chapter: chapter,
  mediaKind: kind,
  logicalId: logicalId,
  timestamp: 1,
  trackingUrl: url,
);

void main() {
  const logicalOnlyManga = 'alias-id';
  const logicalOnlyChapter = 'alias-chapter';
  final logical = logicalDownloadIdForMangaChapter(
    mangaId: logicalOnlyManga,
    chapterId: logicalOnlyChapter,
  ).value;
  final query = _chapter(logicalOnlyManga, logicalOnlyChapter, ' legacy-url ');
  test(
    'earliest complete across key kinds; active rows never win completion',
    () {
      final rows = [
        _row(0, status: TaskStatus.paused, url: 'legacy-url'),
        _row(1, kind: DownloadMediaKind.videoEpisode, logicalId: logical),
        _row(2, chapter: _chapter(' other ', ' 1 ', ' legacy-url ')),
        _row(3, logicalId: ' $logical '),
        _row(4, chapter: _chapter(logicalOnlyManga, logicalOnlyChapter, 'new')),
      ];
      final index = MangaChapterDownloadIndex(rows);
      expect(index.completed(query), same(rows[2]));
      expect(index.alreadyPresent(query), isTrue);

      final active = MangaChapterDownloadIndex(rows.take(2).toList());
      expect(active.completed(query), isNull);
      expect(active.alreadyPresent(query), isTrue);
    },
  );

  test('preserves both one-shot lookups on mixed and conflicting aliases', () {
    final random = Random(24);
    final ids = ['', 'a', ' b ', 'c'];
    final urls = ['', ' u ', 'v', 'w', 'z'];
    T sample<T>(List<T> items) => items[random.nextInt(items.length)];
    final chapters = [
      for (final manga in ids)
        for (final id in ids)
          for (final url in urls) _chapter(manga, id, url),
    ];
    final logicals = [
      '',
      ' bogus ',
      for (final manga in ids.where((id) => id.isNotEmpty))
        for (final id in ids.where((id) => id.isNotEmpty))
          ' ${logicalDownloadIdForMangaChapter(mangaId: manga, chapterId: id).value} ',
    ];
    for (var sampleIndex = 0; sampleIndex < 80; sampleIndex++) {
      final rows = List.generate(
        random.nextInt(40),
        (i) => _row(
          i,
          status: sample(TaskStatus.values),
          kind: sample(DownloadMediaKind.values),
          chapter: random.nextBool() ? null : sample(chapters),
          logicalId: random.nextBool() ? null : sample(logicals),
          url: sample(urls),
        ),
      );
      final index = MangaChapterDownloadIndex(rows);
      for (final chapter in chapters) {
        expect(
          index.completed(chapter),
          same(completedMangaChapterDownload(rows, chapter)),
        );
        expect(
          index.alreadyPresent(chapter),
          mangaChapterDownloadAlreadyPresent(rows, chapter),
        );
      }
    }
  });
}

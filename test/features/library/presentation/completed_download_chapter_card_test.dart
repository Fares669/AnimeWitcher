import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/widgets/completed_download_chapter_card.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

final class _MemoryStorage extends MemoryStorageService {
  @override
  String? getString(String key) => settings[key] as String?;

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      settings.remove(key);
    } else {
      settings[key] = value;
    }
  }

  @override
  Future<void> remove(String key) async {
    settings.remove(key);
  }
}

void main() {
  testWidgets('completed manga chapter mirrors chapter read progress row', (
    tester,
  ) async {
    final repository = MangaReadingRepository(_MemoryStorage());
    await repository.save(
      const MangaReadingProgress(
        mangaId: 'm1',
        chapterId: 'c5',
        pageIndex: 4,
        pageCount: 10,
        updatedAt: 100,
      ),
    );
    final item = DownloadItem(
      task: DownloadTask(
        taskId: 'manga-c5',
        url: 'https://example.test/c5',
        filename: 'c5',
      ),
      status: TaskStatus.complete,
      progress: 1,
      item: MultimediaItem(
        title: 'Manga',
        url: 'https://animewitcher.com/manga/m1',
        posterUrl: 'https://example.test/poster.jpg',
        contentType: MultimediaContentType.manga,
      ),
      chapter: const MangaChapter(
        id: 'c5',
        mangaId: 'm1',
        url: 'https://example.test/c5',
        name: 'Chapter 5',
        number: 5,
      ),
      mediaKind: DownloadMediaKind.mangaChapter,
      timestamp: 1,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaReadingRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CompletedDownloadChapterCard(
              item: item,
              onOpen: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Chapter 5 • 5/10'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline_rounded), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}

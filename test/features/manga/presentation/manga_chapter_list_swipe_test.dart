import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/presentation/widgets/manga_chapter_list.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryStorage extends StorageService {
  final Map<String, String> values = <String, String>{};

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
}

final class _SwipeSettings extends MangaReaderSettingsNotifier {
  _SwipeSettings(this.settings);

  final MangaReaderSettings settings;

  @override
  MangaReaderSettings build() => settings;

  @override
  Future<void> setSettings(MangaReaderSettings value) async {
    state = value;
  }
}

void main() {
  const chapter = MangaChapter(
    id: 'c1',
    mangaId: 'm1',
    url: 'https://example.test/c1',
    name: 'Chapter 1',
    number: 1,
  );

  testWidgets('Mangayomi start chapter swipe toggles bookmark', (tester) async {
    final repository = MangaReadingRepository(_MemoryStorage());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaReadingRepositoryProvider.overrideWithValue(repository),
          mangaReaderSettingsProvider.overrideWith(
            () => _SwipeSettings(const MangaReaderSettings()),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: MangaChapterList(chapters: <MangaChapter>[chapter]),
          ),
        ),
      ),
    );

    expect(find.byType(Dismissible), findsOneWidget);
    await tester.drag(find.byType(Dismissible), const Offset(600, 0));
    await tester.pumpAndSettle();

    expect(repository.get('m1', 'c1')?.isBookmarked, isTrue);
    expect(find.text('Chapter 1'), findsOneWidget);
  });

  testWidgets('Mangayomi end chapter swipe can trigger download', (tester) async {
    MangaChapter? downloaded;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaReadingRepositoryProvider.overrideWithValue(
            MangaReadingRepository(_MemoryStorage()),
          ),
          mangaReaderSettingsProvider.overrideWith(
            () => _SwipeSettings(
              const MangaReaderSettings(
                chapterSwipeEndAction: MangaReaderChapterSwipeAction.download,
              ),
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MangaChapterList(
              chapters: const <MangaChapter>[chapter],
              onDownload: (value) => downloaded = value,
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(Dismissible), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(downloaded?.id, 'c1');
    expect(find.text('Chapter 1'), findsOneWidget);
  });
}

import 'dart:async';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/providers/episode_sort_provider.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/utils/download_time_remaining.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/presentation/widgets/manga_chapter_list.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryStorage extends StorageService {
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

  testWidgets('chapter list shows page progress and has no swipe actions', (
    tester,
  ) async {
    final repository = MangaReadingRepository(_MemoryStorage());
    await repository.save(
      const MangaReadingProgress(
        mangaId: 'm1',
        chapterId: 'c1',
        pageIndex: 4,
        pageCount: 10,
        updatedAt: 100,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_MemoryStorage()),
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

    expect(find.text('Chapter 1 • 5/10'), findsOneWidget);
    expect(find.byType(Dismissible), findsNothing);
  });

  testWidgets('long press selects chapters and read actions update them', (
    tester,
  ) async {
    final repository = MangaReadingRepository(_MemoryStorage());
    const chapters = <MangaChapter>[
      MangaChapter(
        id: 'c2',
        mangaId: 'm1',
        url: 'https://example.test/c2',
        name: 'Chapter 2',
        number: 2,
      ),
      chapter,
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_MemoryStorage()),
          mangaReadingRepositoryProvider.overrideWithValue(repository),
          mangaReaderSettingsProvider.overrideWith(
            () => _SwipeSettings(const MangaReaderSettings()),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: MangaChapterList(chapters: chapters)),
        ),
      ),
    );

    await tester.longPress(find.text('Chapter 2'));
    await tester.pump();

    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Unread'), findsOneWidget);

    await tester.tap(find.text('Chapter 1'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();

    expect(repository.get('m1', 'c1')?.isRead, isTrue);
    expect(repository.get('m1', 'c2')?.isRead, isTrue);
    expect(find.textContaining('selected'), findsNothing);
  });

  testWidgets('downloading chapter replaces download button with progress ring', (
    tester,
  ) async {
    final logicalId = logicalDownloadIdForMangaChapter(
      mangaId: 'm1',
      chapterId: 'c1',
    ).value;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_MemoryStorage()),
          mangaReadingRepositoryProvider.overrideWithValue(
            MangaReadingRepository(_MemoryStorage()),
          ),
          mangaReaderSettingsProvider.overrideWith(
            () => _SwipeSettings(const MangaReaderSettings()),
          ),
          downloadProgressProvider.overrideWithValue(
            <String, DownloadProgressData>{
              logicalId: const DownloadProgressData(
                taskId: 'task-c1',
                progress: 0.42,
                networkSpeed: 1,
                timeRemaining: Duration(seconds: 5),
                status: TaskStatus.running,
              ),
            },
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MangaChapterList(
              chapters: const <MangaChapter>[chapter],
              onDownload: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
  });

  testWidgets('completed chapter shows green downloaded icon', (
    tester,
  ) async {
    final logicalId = logicalDownloadIdForMangaChapter(
      mangaId: 'm1',
      chapterId: 'c1',
    ).value;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_MemoryStorage()),
          mangaReadingRepositoryProvider.overrideWithValue(
            MangaReadingRepository(_MemoryStorage()),
          ),
          mangaReaderSettingsProvider.overrideWith(
            () => _SwipeSettings(const MangaReaderSettings()),
          ),
          downloadProgressProvider.overrideWithValue(
            <String, DownloadProgressData>{
              logicalId: const DownloadProgressData(
                taskId: 'task-c1',
                progress: 1,
                networkSpeed: 0,
                timeRemaining: Duration.zero,
                status: TaskStatus.complete,
              ),
            },
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MangaChapterList(
              chapters: const <MangaChapter>[chapter],
              onDownload: (_) {},
            ),
          ),
        ),
      ),
    );

    final iconFinder = find.byIcon(Icons.download_done_rounded);
    expect(iconFinder, findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(
      tester.widget<Icon>(iconFinder).color,
      const Color(0xFF4CAF50),
    );
  });

  testWidgets('chapter list mirrors episode heading and sort toggle', (
    tester,
  ) async {
    const chapters = <MangaChapter>[
      MangaChapter(
        id: 'c2',
        mangaId: 'm1',
        url: 'https://example.test/c2',
        name: 'Chapter 2',
        number: 2,
      ),
      MangaChapter(
        id: 'c1',
        mangaId: 'm1',
        url: 'https://example.test/c1',
        name: 'Chapter 1',
        number: 1,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_MemoryStorage()),
          mangaReadingRepositoryProvider.overrideWithValue(
            MangaReadingRepository(_MemoryStorage()),
          ),
          mangaReaderSettingsProvider.overrideWith(
            () => _SwipeSettings(const MangaReaderSettings()),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: MangaChapterList(chapters: chapters)),
        ),
      ),
    );

    expect(find.text('Chapters'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Chapter 2')).dy,
      lessThan(tester.getTopLeft(find.text('Chapter 1')).dy),
    );

    await tester.tap(find.byIcon(Icons.arrow_downward_rounded));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Chapter 1')).dy,
      lessThan(tester.getTopLeft(find.text('Chapter 2')).dy),
    );
  });

  testWidgets('manga chapter labels prefix bare server chapter numbers', (
    tester,
  ) async {
    const bareNameChapter = MangaChapter(
      id: 'c201',
      mangaId: 'm1',
      url: 'https://example.test/c201',
      name: '201',
      number: 201,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_MemoryStorage()),
          mangaReadingRepositoryProvider.overrideWithValue(
            MangaReadingRepository(_MemoryStorage()),
          ),
          mangaReaderSettingsProvider.overrideWith(
            () => _SwipeSettings(const MangaReaderSettings()),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: MangaChapterList(chapters: <MangaChapter>[bareNameChapter]),
          ),
        ),
      ),
    );

    expect(find.text('الفصل 201'), findsOneWidget);
    expect(find.text('201'), findsNothing);
  });

  testWidgets('manga chapter sort follows and updates the shared anime setting', (
    tester,
  ) async {
    final storage = _MemoryStorage()
      ..playerSettings[episodeSortAscendingSettingKey] = false;
    const chapters = <MangaChapter>[
      MangaChapter(
        id: 'c2',
        mangaId: 'm1',
        url: 'https://example.test/c2',
        name: 'الفصل 2',
        number: 2,
      ),
      MangaChapter(
        id: 'c1',
        mangaId: 'm1',
        url: 'https://example.test/c1',
        name: 'الفصل 1',
        number: 1,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          mangaReadingRepositoryProvider.overrideWithValue(
            MangaReadingRepository(_MemoryStorage()),
          ),
          mangaReaderSettingsProvider.overrideWith(
            () => _SwipeSettings(const MangaReaderSettings()),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Column(
                children: <Widget>[
                  Text('ascending:${ref.watch(episodeSortAscendingProvider)}'),
                  Expanded(child: MangaChapterList(chapters: chapters)),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('ascending:false'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('الفصل 1')).dy,
      lessThan(tester.getTopLeft(find.text('الفصل 2')).dy),
    );

    await tester.tap(find.byKey(const ValueKey('manga-chapter-sort-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('ascending:true'), findsOneWidget);
    expect(storage.playerSettings[episodeSortAscendingSettingKey], isTrue);
    expect(
      tester.getTopLeft(find.text('الفصل 2')).dy,
      lessThan(tester.getTopLeft(find.text('الفصل 1')).dy),
    );
  });

  testWidgets('read selection closes immediately while cloud sync is pending', (
    tester,
  ) async {
    final syncStarted = Completer<void>();
    final releaseSync = Completer<void>();
    final repository = MangaReadingRepository(
      _MemoryStorage(),
      syncReadStates: (_, __, ___) async {
        if (!syncStarted.isCompleted) syncStarted.complete();
        await releaseSync.future;
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_MemoryStorage()),
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

    await tester.longPress(find.text('Chapter 1'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.text('Read'));
    await tester.pump();
    await syncStarted.future;

    expect(find.textContaining('selected'), findsNothing);
    expect(repository.get('m1', 'c1')?.isRead, isTrue);

    releaseSync.complete();
    await tester.pumpAndSettle();
  });

}

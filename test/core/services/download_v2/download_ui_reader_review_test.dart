import '../../../support/widget_completion.dart';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_screen.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../support/manga_image_fixtures.dart';

class _OfflineProvider extends AnimeWitcherProvider {
  final List<String> requests = [];
  @override
  String get packageName => 'reader.offline';
  @override
  String get name => 'reader';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.manga};
  @override
  Future<List<MultimediaItem>> search(String query, {CancelToken? cancelToken}) async => const [];
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnsupportedError('');
  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];
  @override
  Future<List<MangaPage>> getMangaChapterPages(String mangaUrl, MangaChapter chapter) async {
    requests.add(chapter.id);
    throw StateError('offline');
  }
}

class _Extensions extends ExtensionManager {
  _Extensions(this.provider);
  final AnimeWitcherProvider provider;
  @override
  List<AnimeWitcherProvider> build() => [provider];
}

class _Downloads extends DownloadsNotifier {
  _Downloads(this.items);
  final List<DownloadItem> items;
  @override
  Future<List<DownloadItem>> build() async => items;
}

class _Settings extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings(
    keepScreenOn: false, fullScreen: false, showReadingMode: false,
  );
}

class _ProgressStorage extends StorageService {
  final Map<String, String> values = {};
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) { values.remove(key); } else { values[key] = value; }
  }
}

Future<void> _waitForChapter(WidgetTester tester, String pageUri) => pumpUntil(
  tester, () {
    final readers = find.byType(MangaPagedReader).evaluate();
    if (readers.length != 1) return false;
    final reader = readers.single.widget as MangaPagedReader;
    return reader.pages.length == 1 && reader.pages.single.imageUrl == pageUri;
  }, 'local chapter page $pageUri',
);

void main() {
  testWidgets('reader screen opens Next and Previous downloaded chapters without provider calls', (tester) async {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('aw-ui-offline-')))!;
    addTearDown(() => root.delete(recursive: true));
    final provider = _OfflineProvider();
    final manga = MultimediaItem(
      title: 'Downloaded manga', url: 'manga://ui-offline', posterUrl: '',
      contentType: MultimediaContentType.manga, provider: provider.packageName,
    );
    const chapters = [
      MangaChapter(id: '1', mangaId: 'offline-manga', url: 'chapter://ui-1', name: 'Chapter 1'),
      MangaChapter(id: '2', mangaId: 'offline-manga', url: 'chapter://ui-2', name: 'Chapter 2'),
    ];
    final rows = <DownloadItem>[];
    final pageUris = <String>[];
    await tester.runAsync(() async {
      for (final chapter in chapters) {
        final dir = await Directory('${root.path}/${chapter.id}').create();
        final page = await File('${dir.path}/0001.png').writeAsBytes(tinyMangaPng);
        await MangaChapterManifestV2(
          version: MangaChapterManifestV2.currentVersion, mangaId: chapter.mangaId,
          chapterId: chapter.id, pageCount: 1, completedIndexes: const {0}, isComplete: true,
          pageDigests: {0: await MangaChapterManifestV2.pageDigest(page)},
        ).writeTo(dir);
        pageUris.add(page.uri.toString());
        rows.add(DownloadItem(
          task: DownloadTask(taskId: 'chapter-${chapter.id}', url: 'https://example.test/page', filename: 'chapter'),
          status: TaskStatus.complete, progress: 1, item: manga, chapter: chapter,
          mediaKind: DownloadMediaKind.mangaChapter, destinationPath: dir.path, timestamp: 1,
        ));
      }
    });
    final container = ProviderContainer(overrides: [
      extensionManagerProvider.overrideWith(() => _Extensions(provider)),
      downloadsProvider.overrideWith(() => _Downloads(rows)),
      mangaReaderSettingsProvider.overrideWith(_Settings.new),
      mangaReadingRepositoryProvider.overrideWithValue(MangaReadingRepository(_ProgressStorage())),
    ]);
    addTearDown(container.dispose);
    await pumpUntilFuture(tester, container.read(downloadsProvider.future), 'completed chapter rows');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('ar'), localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MangaReaderScreen(manga: manga, chapter: chapters.first, chapters: chapters,
          localChapterDirectory: rows.first.destinationPath),
      ),
    ));
    await _waitForChapter(tester, pageUris.first);
    expect(tester.widget<MangaPagedReader>(find.byType(MangaPagedReader)).pages.single.imageUrl, pageUris.first);
    expect(provider.requests, isEmpty, reason: 'adjacent downloaded chapters must preload locally');
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await _waitForChapter(tester, pageUris.last);
    expect(tester.widget<MangaPagedReader>(find.byType(MangaPagedReader)).pages.single.imageUrl, pageUris.last);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await _waitForChapter(tester, pageUris.first);
    expect(tester.widget<MangaPagedReader>(find.byType(MangaPagedReader)).pages.single.imageUrl, pageUris.first);
    expect(provider.requests, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/services/download_v2/manga_chapter_manifest_v2.dart';
import '../../../core/services/download_v2/manga_chapter_transport_v2.dart';
import '../../../core/storage/manga_reading_repository.dart';
import 'manga_reader_page_cache.dart';
import 'manga_reader_settings.dart';

export 'manga_reader_settings.dart' show MangaReaderMode;

class MangaReaderController extends ChangeNotifier {
  MangaReaderController({
    required this.provider,
    required this.progressRepository,
    required this.manga,
    required this.chapter,
    required this.chapters,
    this.localChapterDirectory,
    MangaReaderPageCache? pageCache,
    MangaReaderMode? initialMode,
  }) : _chapter = chapter,
       _localChapterId = chapter.id,
       _pageCache = pageCache ?? MangaReaderPageCache(),
       _mode = initialMode ?? preferredModeFor(manga);

  final AnimeWitcherProvider provider;
  final MangaReadingRepository progressRepository;
  final MultimediaItem manga;
  final MangaChapter chapter;
  final List<MangaChapter> chapters;
  final String? localChapterDirectory;
  final String _localChapterId;
  final MangaReaderPageCache _pageCache;

  MangaChapter _chapter;
  MangaReaderMode _mode;
  List<MangaPage> _pages = const <MangaPage>[];
  int _pageIndex = 0;
  bool _loading = true;
  Object? _error;
  Timer? _progressTimer;
  final Map<String, List<MangaPage>> _preloadedChapterPages =
      <String, List<MangaPage>>{};
  final Set<String> _preloadingChapterIds = <String>{};
  bool _autoReadDuplicateChapters = false;
  String? _lastLoadChapterId;
  bool _attemptedPageRefresh = false;
  Future<void>? _refreshingPages;
  String? _refreshingChapterId;

  static MangaReaderMode preferredModeFor(MultimediaItem item) {
    final type = (item.catalogType ?? '').trim().toLowerCase();
    if (type.contains('مانهوا') || type.contains('manhwa')) {
      return MangaReaderMode.webtoon;
    }
    return MangaReaderMode.pagedRtl;
  }

  MangaChapter get currentChapter => _chapter;
  MangaReaderMode get mode => _mode;
  List<MangaPage> get pages => _pages;
  int get pageIndex => _pageIndex;
  bool get isLoading => _loading;
  Object? get error => _error;

  int get currentChapterIndex {
    final byId = chapters.indexWhere(
      (value) =>
          value.id == _chapter.id ||
          (value.url.isNotEmpty && value.url == _chapter.url),
    );
    return byId;
  }

  bool get canPrevious => currentChapterIndex > 0;
  String get mangaId => _mangaId;
  bool get isBookmarked =>
      progressRepository.get(_mangaId, _chapter.id)?.isBookmarked ?? false;
  bool get canNext {
    final index = currentChapterIndex;
    return index >= 0 && index + 1 < chapters.length;
  }

  String get _mangaId {
    final chapterId = _chapter.mangaId.trim();
    if (chapterId.isNotEmpty) return chapterId;
    final syncId = manga.syncData?['mangaId']?.trim() ?? '';
    return syncId.isNotEmpty ? syncId : manga.url;
  }

  Future<void> load() async {
    _progressTimer?.cancel();
    final chapterId = _chapter.id;
    final forceSourceReload = _lastLoadChapterId == chapterId;
    _lastLoadChapterId = chapterId;
    _attemptedPageRefresh = false;
    _loading = true;
    _error = null;
    _pages = const <MangaPage>[];
    notifyListeners();

    try {
      final localPages = await _loadLocalPages();
      if (forceSourceReload && localPages.isEmpty) {
        _preloadedChapterPages.remove(chapterId);
        await _pageCache.remove(_mangaId, _chapter);
      }
      final preloaded = localPages.isEmpty && !forceSourceReload
          ? _preloadedChapterPages.remove(chapterId)
          : null;
      final cached =
          localPages.isEmpty && !forceSourceReload && preloaded == null
          ? await _pageCache.get(_mangaId, _chapter)
          : null;
      final remote =
          localPages.isEmpty &&
              (forceSourceReload || (preloaded == null && cached == null))
          ? await provider.getMangaChapterPages(manga.url, _chapter)
          : null;
      final pages = localPages.isNotEmpty
          ? localPages
          : preloaded ?? cached ?? remote ?? const <MangaPage>[];
      if (remote != null && remote.isNotEmpty) {
        await _pageCache.put(_mangaId, _chapter, remote);
      }
      _pages = pages;
      final saved = progressRepository.get(_mangaId, _chapter.id);
      final maxPage = pages.isEmpty ? 0 : pages.length - 1;
      _pageIndex = (saved?.pageIndex ?? 0).clamp(0, maxPage).toInt();
      _loading = false;
      _error = null;
      notifyListeners();
      unawaited(_preloadAdjacentChapters());
    } catch (error) {
      _loading = false;
      _error = error;
      notifyListeners();
    }
  }


  Future<void> refreshFailedPage(MangaPage failedPage) async {
    if (failedPage.imageUrl.startsWith('file:') ||
        !_pages.any((page) => page.imageUrl == failedPage.imageUrl)) {
      return;
    }
    final activeRefresh = _refreshingPages;
    if (_refreshingChapterId == _chapter.id && activeRefresh != null) {
      return activeRefresh;
    }
    if (_attemptedPageRefresh) return;
    _attemptedPageRefresh = true;
    final chapter = _chapter;
    final future = () async {
      try {
        final fresh = await provider.refreshMangaChapterPages(manga.url, chapter);
        if (chapter.id != _chapter.id || fresh.isEmpty) return;
        final unchanged =
            fresh.length == _pages.length &&
            List<int>.generate(fresh.length, (index) => index).every(
              (index) =>
                  fresh[index].imageUrl == _pages[index].imageUrl &&
                  mapEquals(fresh[index].headers, _pages[index].headers),
            );
        if (unchanged) return;
        _pages = fresh;
        _pageIndex = _pageIndex.clamp(0, fresh.length - 1).toInt();
        await _pageCache.put(_mangaId, chapter, fresh);
        notifyListeners();
      } catch (_) {
        // Keep the current pages and let the reader offer its manual retry.
      }
    }();
    _refreshingPages = future;
    _refreshingChapterId = chapter.id;
    try {
      await future;
    } finally {
      if (identical(_refreshingPages, future)) {
        _refreshingPages = null;
        _refreshingChapterId = null;
      }
    }
  }

  Future<void> _preloadAdjacentChapters() async {
    final index = currentChapterIndex;
    if (index < 0 || chapters.isEmpty) return;

    final adjacent = <MangaChapter>[
      if (index > 0) chapters[index - 1],
      if (index + 1 < chapters.length) chapters[index + 1],
    ];

    await Future.wait<void>(
      adjacent.map((chapter) async {
        final id = chapter.id;
        if (id.isEmpty ||
            id == _chapter.id ||
            _preloadedChapterPages.containsKey(id) ||
            !_preloadingChapterIds.add(id)) {
          return;
        }
        try {
          final cached = await _pageCache.get(_mangaId, chapter);
          final pages =
              cached ?? await provider.getMangaChapterPages(manga.url, chapter);
          if (pages.isNotEmpty) {
            _preloadedChapterPages[id] = List<MangaPage>.unmodifiable(pages);
            if (cached == null) {
              await _pageCache.put(_mangaId, chapter, pages);
            }
          }
        } catch (_) {
          // Preload failures must never interrupt the chapter currently open.
        } finally {
          _preloadingChapterIds.remove(id);
        }
      }),
    );
  }

  Future<List<MangaPage>> _loadLocalPages() async {
    final rawDirectory = localChapterDirectory?.trim() ?? '';
    if (rawDirectory.isEmpty || _chapter.id != _localChapterId) {
      return const <MangaPage>[];
    }

    final directory = await resolveMangaChapterDirectoryV2(rawDirectory);
    if (!await directory.exists()) return const <MangaPage>[];
    final manifest = await MangaChapterManifestV2.readFrom(directory);
    if (manifest == null ||
        !manifest.isComplete ||
        manifest.mangaId != _mangaId ||
        manifest.chapterId != _chapter.id ||
        manifest.pageCount <= 0) {
      return const <MangaPage>[];
    }

    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          p.basename(entity.path) != MangaChapterManifestV2.fileName &&
          !entity.path.endsWith('.tmp')) {
        files.add(entity);
      }
    }

    final pages = <MangaPage>[];
    for (var index = 0; index < manifest.pageCount; index++) {
      final prefix = (index + 1).toString().padLeft(4, '0');
      File? pageFile;
      for (final file in files) {
        if (p.basename(file.path).startsWith('$prefix.')) {
          pageFile = file;
          break;
        }
      }
      if (pageFile == null || await pageFile.length() <= 0) {
        return const <MangaPage>[];
      }
      pages.add(MangaPage(index: index, imageUrl: pageFile.uri.toString()));
    }
    return pages;
  }

  void setMode(MangaReaderMode value) {
    if (_mode == value) return;
    _mode = value;
    notifyListeners();
  }

  void setPageIndex(
    int value, {
    bool autoReadDuplicateChapters = false,
  }) {
    _autoReadDuplicateChapters = autoReadDuplicateChapters;
    if (_pages.isEmpty) return;
    final next = value.clamp(0, _pages.length - 1).toInt();
    if (_pageIndex == next) return;
    _pageIndex = next;
    notifyListeners();
    _scheduleProgressSave();
  }

  void _scheduleProgressSave() {
    _progressTimer?.cancel();
    _progressTimer = Timer(
      const Duration(seconds: 1),
      () => unawaited(flushProgress()),
    );
  }

  double? _recognizedChapterNumber(MangaChapter chapter) {
    if (chapter.number != null) return chapter.number;
    final match = RegExp(r'\d+(?:[.,]\d+)?').firstMatch(chapter.name);
    return double.tryParse((match?.group(0) ?? '').replaceAll(',', '.'));
  }

  bool get _shouldMarkCurrentChapterRead =>
      _pages.isNotEmpty && _pageIndex >= _pages.length - 1;

  Future<void> _markDuplicateChaptersRead() async {
    final currentNumber = _recognizedChapterNumber(_chapter);
    if (currentNumber == null) return;
    for (final sibling in chapters) {
      if (sibling.id == _chapter.id ||
          _recognizedChapterNumber(sibling) != currentNumber) {
        continue;
      }
      final current = progressRepository.get(_mangaId, sibling.id);
      if (current?.isRead == true) continue;
      await progressRepository.markRead(
        _mangaId,
        sibling.id,
        pageCount: current?.pageCount ?? 1,
      );
    }
  }

  Future<void> flushProgress() async {
    if (_pages.isEmpty) return;
    final previous = progressRepository.get(_mangaId, _chapter.id);
    final isRead =
        (previous?.isRead ?? false) || _shouldMarkCurrentChapterRead;
    await progressRepository.save(
      MangaReadingProgress(
        mangaId: _mangaId,
        chapterId: _chapter.id,
        pageIndex: _pageIndex,
        pageCount: _pages.length,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        isRead: isRead,
        isBookmarked: previous?.isBookmarked ?? false,
      ),
    );
    if (isRead && _autoReadDuplicateChapters) {
      await _markDuplicateChaptersRead();
    }
  }

  Future<void> toggleBookmark() async {
    if (_pages.isEmpty) return;
    await flushProgress();
    await progressRepository.toggleBookmark(_mangaId, _chapter.id);
    notifyListeners();
  }

  void jumpToPage(int value) {
    setPageIndex(value);
  }

  Future<void> openChapter(MangaChapter value) async {
    if (value.id == _chapter.id && value.url == _chapter.url) return;
    await flushProgress();
    _chapter = value;
    _pageIndex = 0;
    await load();
  }

  Future<void> previousChapter() async {
    final index = currentChapterIndex;
    if (index <= 0) return;
    await openChapter(chapters[index - 1]);
  }

  Future<void> nextChapter() async {
    final index = currentChapterIndex;
    if (index < 0 || index + 1 >= chapters.length) return;
    await openChapter(chapters[index + 1]);
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _preloadedChapterPages.clear();
    _preloadingChapterIds.clear();
    unawaited(flushProgress());
    super.dispose();
  }
}

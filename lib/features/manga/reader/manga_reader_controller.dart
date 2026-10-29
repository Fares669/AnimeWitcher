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
    required MangaChapter chapter,
    required this.chapters,
    this.localChapterDirectory,
    this.localChapterDirectoryFor,
    MangaReaderPageCache? pageCache,
    MangaReaderMode? initialMode,
  }) : _chapter = chapter,
       _initialLocalChapter = chapter,
       _pageCache = pageCache ?? MangaReaderPageCache(),
       _mode = initialMode ?? preferredModeFor(manga);

  final AnimeWitcherProvider provider;
  final MangaReadingRepository progressRepository;
  final MultimediaItem manga;
  final List<MangaChapter> chapters;
  final String? localChapterDirectory;
  final MangaChapter _initialLocalChapter;
  final Future<String?> Function(MangaChapter chapter)?
  localChapterDirectoryFor;
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
  final Set<Future<void>> _cacheOperations = <Future<void>>{};
  bool _disposed = false;
  Future<void>? _closing;
  bool _autoReadDuplicateChapters = false;
  String? _lastLoadChapterId;

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

  String get _mangaId => _mangaIdFor(_chapter);

  String _mangaIdFor(MangaChapter chapter) {
    final chapterId = chapter.mangaId.trim();
    if (chapterId.isNotEmpty) return chapterId;
    final syncId = manga.syncData?['mangaId']?.trim() ?? '';
    return syncId.isNotEmpty ? syncId : manga.url;
  }

  Future<void> load() async {
    if (_disposed) return;
    _progressTimer?.cancel();
    final chapterId = _chapter.id;
    final forceSourceReload = _lastLoadChapterId == chapterId;
    _lastLoadChapterId = chapterId;
    _loading = true;
    _error = null;
    _pages = const <MangaPage>[];
    notifyListeners();

    try {
      final localPages = await _loadLocalPages(_chapter);
      if (_disposed) return;
      if (forceSourceReload && localPages.isEmpty) {
        _preloadedChapterPages.remove(chapterId);
        await _trackCacheOperation(_pageCache.remove(_mangaId, _chapter));
        if (_disposed) return;
      }
      final preloaded = localPages.isEmpty && !forceSourceReload
          ? _preloadedChapterPages.remove(chapterId)
          : null;
      final cached =
          localPages.isEmpty && !forceSourceReload && preloaded == null
          ? await _trackCacheOperation(_pageCache.get(_mangaId, _chapter))
          : null;
      if (_disposed) return;
      final remote =
          localPages.isEmpty &&
              (forceSourceReload || (preloaded == null && cached == null))
          ? await provider.getMangaChapterPages(manga.url, _chapter)
          : null;
      if (_disposed) return;
      final pages = localPages.isNotEmpty
          ? localPages
          : preloaded ?? cached ?? remote ?? const <MangaPage>[];
      if (remote != null && remote.isNotEmpty) {
        await _trackCacheOperation(_pageCache.put(_mangaId, _chapter, remote));
        if (_disposed) return;
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
      if (_disposed) return;
      _loading = false;
      _error = error;
      notifyListeners();
    }
  }

  /// Resolves a chapter's pages without opening it: downloaded pages
  /// first, then the preload this controller already fetched, then the
  /// page-list cache, then the source. Used by the scrolling readers'
  /// connected chapter stream, which shows neighbouring chapters in the
  /// same scroll instead of navigating to them. Failures return an empty
  /// list — a stream segment that cannot be resolved is simply skipped.
  Future<List<MangaPage>> fetchChapterPages(MangaChapter chapter) async {
    if (_disposed) return const <MangaPage>[];
    try {
      final local = await _loadLocalPages(chapter);
      if (_disposed) return const <MangaPage>[];
      if (local.isNotEmpty) return List<MangaPage>.unmodifiable(local);
      final preloaded = _preloadedChapterPages.remove(chapter.id);
      if (preloaded != null && preloaded.isNotEmpty) return preloaded;
      final mangaId = _mangaIdFor(chapter);
      final cached = await _trackCacheOperation(
        _pageCache.get(mangaId, chapter),
      );
      if (_disposed) return const <MangaPage>[];
      if (cached != null && cached.isNotEmpty) {
        return List<MangaPage>.unmodifiable(cached);
      }
      final remote = await provider.getMangaChapterPages(manga.url, chapter);
      if (_disposed) return const <MangaPage>[];
      if (remote.isNotEmpty) {
        await _trackCacheOperation(_pageCache.put(mangaId, chapter, remote));
      }
      return List<MangaPage>.unmodifiable(remote);
    } catch (_) {
      return const <MangaPage>[];
    }
  }

  /// Moves the reading position into a chapter the stream already shows,
  /// without loading anything: progress for the chapter being left is
  /// flushed, and the current chapter, its pages and the page index now
  /// describe the segment on screen, so the bars, the page pill and
  /// progress saving keep following the reader across segment seams.
  Future<void> adoptStreamChapter(
    MangaChapter chapter,
    List<MangaPage> pages,
    int pageIndex, {
    bool autoReadDuplicateChapters = false,
  }) async {
    if (_disposed || pages.isEmpty) return;
    _autoReadDuplicateChapters = autoReadDuplicateChapters;
    final sameChapter =
        chapter.id == _chapter.id && chapter.url == _chapter.url;
    if (!sameChapter) {
      await flushProgress();
      if (_disposed) return;
      _chapter = chapter;
    }
    _pages = List<MangaPage>.unmodifiable(pages);
    _pageIndex = pageIndex.clamp(0, pages.length - 1).toInt();
    notifyListeners();
    _scheduleProgressSave();
    if (!sameChapter) unawaited(_preloadAdjacentChapters());
  }

  Future<void> _preloadAdjacentChapters() async {
    if (_disposed) return;
    final index = currentChapterIndex;
    if (index < 0 || chapters.isEmpty) return;

    final adjacent = <MangaChapter>[
      if (index > 0) chapters[index - 1],
      if (index + 1 < chapters.length) chapters[index + 1],
    ];

    await Future.wait<void>(
      adjacent.map((chapter) async {
        final id = chapter.id;
        if (_disposed ||
            id.isEmpty ||
            id == _chapter.id ||
            _preloadedChapterPages.containsKey(id) ||
            !_preloadingChapterIds.add(id)) {
          return;
        }
        try {
          final local = await _loadLocalPages(chapter);
          if (_disposed) return;
          final mangaId = _mangaIdFor(chapter);
          final cached = local.isEmpty
              ? await _trackCacheOperation(_pageCache.get(mangaId, chapter))
              : null;
          if (_disposed) return;
          final pages = local.isNotEmpty
              ? local
              : cached ??
                    await provider.getMangaChapterPages(manga.url, chapter);
          if (_disposed) return;
          // Local pages must be validated again when actually navigating.
          if (pages.isNotEmpty && local.isEmpty) {
            _preloadedChapterPages[id] = List<MangaPage>.unmodifiable(pages);
            if (local.isEmpty && cached == null) {
              await _trackCacheOperation(
                _pageCache.put(mangaId, chapter, pages),
              );
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

  Future<List<MangaPage>> _loadLocalPages(MangaChapter chapter) async {
    if (_disposed) return const <MangaPage>[];
    String? resolvedDirectory;
    try {
      resolvedDirectory = await localChapterDirectoryFor?.call(chapter);
    } catch (_) {
      // An unavailable downloads projection must not hide the initial directory.
    }
    if (_disposed) return const <MangaPage>[];
    final initial =
        chapter.id == _initialLocalChapter.id &&
        _mangaIdFor(chapter) == _mangaIdFor(_initialLocalChapter);
    final rawDirectory = (resolvedDirectory?.trim().isNotEmpty ?? false)
        ? resolvedDirectory!.trim()
        : initial
        ? localChapterDirectory?.trim() ?? ''
        : '';
    if (rawDirectory.isEmpty) return const <MangaPage>[];

    final directory = await resolveMangaChapterDirectoryV2(rawDirectory);
    if (!await directory.exists()) return const <MangaPage>[];
    final manifest = await MangaChapterManifestV2.readFrom(directory);
    if (manifest == null ||
        !manifest.isComplete ||
        manifest.mangaId != _mangaIdFor(chapter) ||
        manifest.chapterId != chapter.id ||
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
        if (p.basename(file.path).startsWith('$prefix.') &&
            await manifest.isPageValid(index, file)) {
          pageFile = file;
          break;
        }
      }
      if (pageFile == null) {
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

  void setPageIndex(int value, {bool autoReadDuplicateChapters = false}) {
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
    final isRead = (previous?.isRead ?? false) || _shouldMarkCurrentChapterRead;
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

  Future<void> openChapter(MangaChapter value) async {
    if (_disposed) return;
    if (value.id == _chapter.id && value.url == _chapter.url) return;
    await flushProgress();
    if (_disposed) return;
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
    if (_disposed) return;
    _disposed = true;
    _progressTimer?.cancel();
    _preloadedChapterPages.clear();
    _preloadingChapterIds.clear();
    _closing = Future.wait<void>([..._cacheOperations, flushProgress()]);
    // Widgets dispose synchronously; close() still exposes a flush failure to
    // callers that explicitly await shutdown.
    _closing!.ignore();
    super.dispose();
  }

  /// Stops loading/preloading and drains accepted cache I/O and the final
  /// progress flush. Closing never waits for an extension page request.
  Future<void> close() {
    dispose();
    return _closing!;
  }

  Future<T> _trackCacheOperation<T>(Future<T> operation) {
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _cacheOperations.add(settled);
    unawaited(settled.whenComplete(() => _cacheOperations.remove(settled)));
    return operation;
  }
}

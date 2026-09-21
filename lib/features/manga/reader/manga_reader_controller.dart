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
    MangaReaderMode? initialMode,
  }) : _chapter = chapter,
       _localChapterId = chapter.id,
       _mode = initialMode ?? preferredModeFor(manga);

  final AnimeWitcherProvider provider;
  final MangaReadingRepository progressRepository;
  final MultimediaItem manga;
  final MangaChapter chapter;
  final List<MangaChapter> chapters;
  final String? localChapterDirectory;
  final String _localChapterId;

  MangaChapter _chapter;
  MangaReaderMode _mode;
  List<MangaPage> _pages = const <MangaPage>[];
  int _pageIndex = 0;
  bool _loading = true;
  Object? _error;
  Timer? _progressTimer;

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
    _loading = true;
    _error = null;
    _pages = const <MangaPage>[];
    notifyListeners();

    try {
      final localPages = await _loadLocalPages();
      final pages = localPages.isNotEmpty
          ? localPages
          : await provider.getMangaChapterPages(manga.url, _chapter);
      _pages = pages;
      final saved = progressRepository.get(_mangaId, _chapter.id);
      final maxPage = pages.isEmpty ? 0 : pages.length - 1;
      _pageIndex = (saved?.pageIndex ?? 0).clamp(0, maxPage).toInt();
      _loading = false;
      _error = null;
      notifyListeners();
    } catch (error) {
      _loading = false;
      _error = error;
      notifyListeners();
    }
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

  void setPageIndex(int value) {
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

  Future<void> flushProgress() async {
    if (_pages.isEmpty) return;
    final previous = progressRepository.get(_mangaId, _chapter.id);
    await progressRepository.save(
      MangaReadingProgress(
        mangaId: _mangaId,
        chapterId: _chapter.id,
        pageIndex: _pageIndex,
        pageCount: _pages.length,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        isRead: _pageIndex >= _pages.length - 1,
        isBookmarked: previous?.isBookmarked ?? false,
      ),
    );
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
    unawaited(flushProgress());
    super.dispose();
  }
}

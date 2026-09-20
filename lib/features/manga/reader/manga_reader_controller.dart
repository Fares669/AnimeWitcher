import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/storage/manga_reading_repository.dart';

enum MangaReaderMode { webtoon, pagedLtr, pagedRtl }

class MangaReaderController extends ChangeNotifier {
  MangaReaderController({
    required this.provider,
    required this.progressRepository,
    required this.manga,
    required this.chapter,
    required this.chapters,
    MangaReaderMode? initialMode,
  }) : _chapter = chapter,
       _mode = initialMode ?? preferredModeFor(manga);

  final AnimeWitcherProvider provider;
  final MangaReadingRepository progressRepository;
  final MultimediaItem manga;
  final MangaChapter chapter;
  final List<MangaChapter> chapters;

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
      final pages = await provider.getMangaChapterPages(manga.url, _chapter);
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
    await progressRepository.save(
      MangaReadingProgress(
        mangaId: _mangaId,
        chapterId: _chapter.id,
        pageIndex: _pageIndex,
        pageCount: _pages.length,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        isRead: _pageIndex >= _pages.length - 1,
      ),
    );
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

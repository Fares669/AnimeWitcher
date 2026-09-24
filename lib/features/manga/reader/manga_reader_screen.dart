import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/storage/manga_reading_repository.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import '../../../shared/widgets/loading_indicator.dart';
import 'manga_reader_controller.dart';
import 'manga_reader_keyboard_handler.dart';
import 'manga_reader_image_actions.dart';
import 'manga_reader_cover_provider.dart';
import 'manga_reader_settings.dart';
import 'manga_reader_settings_provider.dart';
import 'manga_reader_settings_screen.dart';
import 'widgets/manga_continuous_reader.dart';
import 'widgets/manga_chapter_transition_page.dart';
import 'widgets/manga_reader_auto_scroll_button.dart';
import 'widgets/manga_reader_image_actions_sheet.dart';
import 'widgets/manga_reader_navigation_overlay.dart';
import 'widgets/manga_reader_page_indicator.dart';
import 'widgets/manga_reader_quick_settings.dart';
import 'widgets/manga_paged_reader.dart';
import 'widgets/manga_webtoon_reader.dart';
import 'widgets/manga_zoomable_page.dart';

class MangaReaderScreen extends ConsumerStatefulWidget {
  const MangaReaderScreen({
    super.key,
    required this.manga,
    required this.chapter,
    required this.chapters,
    this.localChapterDirectory,
  });

  final MultimediaItem manga;
  final MangaChapter chapter;
  final List<MangaChapter> chapters;
  final String? localChapterDirectory;

  @override
  ConsumerState<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

class _MangaReaderScreenState extends ConsumerState<MangaReaderScreen>
    with WidgetsBindingObserver {
  late final MangaReaderController _controller;
  final MangaZoomNavigationController _zoomNavigationController =
      MangaZoomNavigationController();
  final ScrollController _continuousController = ScrollController();
  final FocusNode _keyboardFocusNode = FocusNode();

  Timer? _autoScrollTimer;
  Timer? _flashTimer;
  bool _controlsVisible = true;
  bool _forceDoublePage = false;
  bool _autoScrollRunning = false;
  bool _showNavigationOverlay = false;
  bool _flashVisible = false;
  int _readerEpoch = 0;
  int _pageChangeCount = 0;
  bool? _keepAwakeApplied;
  bool? _fullScreenApplied;
  bool _chapterNavigationInProgress = false;

  String get _readerMangaId {
    final chapterId = widget.chapter.mangaId.trim();
    if (chapterId.isNotEmpty) return chapterId;
    final syncId = widget.manga.syncData?['mangaId']?.trim() ?? '';
    return syncId.isNotEmpty ? syncId : widget.manga.url;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final provider = _resolveProvider();
    final settings = ref.read(mangaReaderSettingsProvider);
    final autoScroll = settings.autoScrollForManga(_readerMangaId);
    _autoScrollRunning = autoScroll.enabled;
    _forceDoublePage = settings.doublePageForManga(_readerMangaId);
    _showNavigationOverlay = settings.showNavigationOverlayOnStart;
    _controller = MangaReaderController(
      provider: provider,
      progressRepository: ref.read(mangaReadingRepositoryProvider),
      manga: widget.manga,
      chapter: widget.chapter,
      chapters: widget.chapters,
      localChapterDirectory: widget.localChapterDirectory,
      initialMode: settings.modeForManga(_readerMangaId),
    );
    _controller.addListener(_handleControllerChanged);
    _controller.load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncDeviceState(settings);
      _syncAutoScroll(settings);
      _keyboardFocusNode.requestFocus();
    });
  }

  AnimeWitcherProvider _resolveProvider() {
    final manager = ref.read(extensionManagerProvider.notifier);
    final requested = widget.manga.provider?.trim() ?? '';
    final selected = requested.isEmpty ? null : manager.getProvider(requested);
    if (selected != null) return selected;
    for (final provider in manager.getAllProviders()) {
      if (provider.supportedTypes.contains(ProviderType.manga)) return provider;
    }
    throw StateError('No Manga provider is available.');
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final settings = ref.read(mangaReaderSettingsProvider);
    if (state == AppLifecycleState.resumed) {
      _syncDeviceState(settings);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_controller.flushProgress());
      if (settings.keepScreenOn) {
        unawaited(WakelockPlus.disable().catchError((_) {}));
        _keepAwakeApplied = false;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoScrollTimer?.cancel();
    _flashTimer?.cancel();
    _continuousController.dispose();
    _keyboardFocusNode.dispose();
    _controller.removeListener(_handleControllerChanged);
    _controller.dispose();
    unawaited(WakelockPlus.disable().catchError((_) {}));
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
          .catchError((_) {}),
    );
    super.dispose();
  }

  void _syncDeviceState(MangaReaderSettings settings) {
    if (_keepAwakeApplied != settings.keepScreenOn) {
      _keepAwakeApplied = settings.keepScreenOn;
      unawaited(
        (settings.keepScreenOn ? WakelockPlus.enable() : WakelockPlus.disable())
            .catchError((_) {}),
      );
    }
    if (_fullScreenApplied != settings.fullScreen) {
      _fullScreenApplied = settings.fullScreen;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          settings.fullScreen
              ? SystemUiMode.immersiveSticky
              : SystemUiMode.edgeToEdge,
        ).catchError((_) {}),
      );
    }
  }

  void _syncAutoScroll(MangaReaderSettings settings) {
    final autoScroll = settings.autoScrollForManga(_readerMangaId);
    final shouldRun =
        _autoScrollRunning &&
        autoScroll.enabled &&
        _controller.mode.isContinuous;
    if (!shouldRun) {
      _autoScrollTimer?.cancel();
      _autoScrollTimer = null;
      return;
    }
    if (_autoScrollTimer?.isActive == true) return;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || !_continuousController.hasClients) return;
      final position = _continuousController.position;
      final delta = autoScroll.speed * 0.15;
      final target = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() < 0.1) {
        if (_chapterNavigationInProgress) return;
        _autoScrollTimer?.cancel();
        _autoScrollTimer = null;
        if (_controller.canNext) {
          unawaited(
            _navigateChapter(next: true).then((_) {
              if (!mounted || !_autoScrollRunning) return;
              _syncAutoScroll(ref.read(mangaReaderSettingsProvider));
            }),
          );
          return;
        }
        _autoScrollRunning = false;
        if (mounted) setState(() {});
        return;
      }
      _continuousController.jumpTo(target.toDouble());
    });
  }

  void _setAutoScroll({required bool enabled, required double speed}) {
    final settings = ref.read(mangaReaderSettingsProvider);
    final next = settings.withMangaAutoScroll(
      _readerMangaId,
      enabled: enabled,
      speed: speed,
    );
    setState(() => _autoScrollRunning = enabled);
    unawaited(
      ref.read(mangaReaderSettingsProvider.notifier).setSettings(next),
    );
    _syncAutoScroll(next);
  }

  void _toggleAutoScroll(MangaReaderSettings settings) {
    final current = settings.autoScrollForManga(_readerMangaId);
    _setAutoScroll(enabled: !current.enabled, speed: current.speed);
  }

  void _setMode(MangaReaderMode mode, MangaReaderSettings settings) {
    _controller.setMode(mode);
    final next = settings.withMangaMode(_readerMangaId, mode);
    unawaited(
      ref.read(mangaReaderSettingsProvider.notifier).setSettings(next),
    );
    setState(() {
      _readerEpoch++;
      if (!mode.isContinuous) _autoScrollRunning = false;
    });
    _syncAutoScroll(next);
  }

  void _toggleDoublePage(MangaReaderSettings settings) {
    final nextValue = !_forceDoublePage;
    final next = settings.withMangaDoublePage(_readerMangaId, nextValue);
    setState(() => _forceDoublePage = nextValue);
    unawaited(
      ref.read(mangaReaderSettingsProvider.notifier).setSettings(next),
    );
  }

  void _onPageChanged(int index, MangaReaderSettings settings) {
    _controller.setPageIndex(
      index,
      autoReadDuplicateChapters: settings.autoReadDuplicateChapters,
    );
    _pageChangeCount++;
    if (!settings.flashOnPageChange ||
        _pageChangeCount % settings.flashInterval != 0) {
      return;
    }
    _flashTimer?.cancel();
    setState(() => _flashVisible = true);
    _flashTimer = Timer(
      Duration(milliseconds: settings.flashDurationMs),
      () {
        if (mounted) setState(() => _flashVisible = false);
      },
    );
  }

  void _jumpToPage(int index) {
    if (_controller.pages.isEmpty) return;
    _controller.jumpToPage(
      index.clamp(0, _controller.pages.length - 1).toInt(),
    );
    setState(() => _readerEpoch++);
  }

  void _previousPage() => _jumpToPage(_controller.pageIndex - 1);
  void _nextPage() => _jumpToPage(_controller.pageIndex + 1);

  void _navigateReaderPage({
    required bool forward,
    required MangaReaderSettings settings,
  }) {
    if (_controller.mode.isContinuous && _continuousController.hasClients) {
      final position = _continuousController.position;
      if (forward &&
          position.extentAfter <= 0.5 &&
          _controller.canNext) {
        _openNextChapter();
        return;
      }
      if (!forward &&
          position.extentBefore <= 0.5 &&
          _controller.canPrevious) {
        _openPreviousChapter();
        return;
      }

      final viewport = MediaQuery.sizeOf(context);
      final horizontal =
          _controller.mode == MangaReaderMode.horizontalContinuous ||
          _controller.mode == MangaReaderMode.horizontalContinuousRtl;
      final dimension = horizontal ? viewport.width : viewport.height;
      final offset = dimension * 0.60 * (forward ? 1 : -1);
      final target = (position.pixels + offset)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      unawaited(
        _continuousController
            .animateTo(
              target,
              duration: settings.animatePageTransitions
                  ? const Duration(milliseconds: 160)
                  : const Duration(milliseconds: 10),
              curve: Curves.easeInOut,
            )
            .catchError((_) {}),
      );
      return;
    }
    if (settings.navigateToPan &&
        _zoomNavigationController.tryPan(
          forward: forward,
          rtl: _controller.mode.isRtl,
        )) {
      return;
    }
    if (forward &&
        _controller.pageIndex >= _controller.pages.length - 1 &&
        _controller.canNext) {
      _openNextChapter();
      return;
    }
    if (!forward && _controller.pageIndex <= 0 && _controller.canPrevious) {
      _openPreviousChapter();
      return;
    }
    forward ? _nextPage() : _previousPage();
  }

  VoidCallback _horizontalPrevious(MangaReaderSettings settings) {
    final invert = settings.tappingInversion == 1 ||
        settings.tappingInversion == 3;
    final rtl = _controller.mode.isRtl;
    final previous = rtl
        ? () => _navigateReaderPage(forward: true, settings: settings)
        : () => _navigateReaderPage(forward: false, settings: settings);
    final next = rtl
        ? () => _navigateReaderPage(forward: false, settings: settings)
        : () => _navigateReaderPage(forward: true, settings: settings);
    return invert ? next : previous;
  }

  VoidCallback _horizontalNext(MangaReaderSettings settings) {
    final invert = settings.tappingInversion == 1 ||
        settings.tappingInversion == 3;
    final rtl = _controller.mode.isRtl;
    final previous = rtl
        ? () => _navigateReaderPage(forward: true, settings: settings)
        : () => _navigateReaderPage(forward: false, settings: settings);
    final next = rtl
        ? () => _navigateReaderPage(forward: false, settings: settings)
        : () => _navigateReaderPage(forward: true, settings: settings);
    return invert ? previous : next;
  }

  void _handleTapZone(
    TapUpDetails details,
    Size size,
    MangaReaderSettings settings,
  ) {
    if (!settings.usePageTapZones || settings.navigationLayout == 5) {
      setState(() => _controlsVisible = !_controlsVisible);
      return;
    }
    final x = size.width <= 0 ? 0.5 : details.localPosition.dx / size.width;
    final y = size.height <= 0 ? 0.5 : details.localPosition.dy / size.height;
    final previous = _horizontalPrevious(settings);
    final next = _horizontalNext(settings);
    final verticalInvert =
        settings.tappingInversion == 2 || settings.tappingInversion == 3;
    final top = verticalInvert
        ? () => _navigateReaderPage(forward: true, settings: settings)
        : () => _navigateReaderPage(forward: false, settings: settings);
    final bottom = verticalInvert
        ? () => _navigateReaderPage(forward: false, settings: settings)
        : () => _navigateReaderPage(forward: true, settings: settings);

    switch (settings.navigationLayout) {
      case 1:
        if (y < .25 && x < 1 / 3) {
          previous();
        } else if (y > .75 && x > 2 / 3) {
          next();
        } else {
          setState(() => _controlsVisible = !_controlsVisible);
        }
      case 2:
        if (y < .25) {
          setState(() => _controlsVisible = !_controlsVisible);
        } else if (x < .5) {
          previous();
        } else {
          next();
        }
      case 3:
        if (x < 1 / 7) {
          previous();
        } else if (x > 6 / 7) {
          next();
        } else {
          setState(() => _controlsVisible = !_controlsVisible);
        }
      case 4:
        x < .5 ? previous() : next();
      default:
        if (y < 2 / 9) {
          top();
        } else if (y > 7 / 9) {
          bottom();
        } else if (x < 1 / 3) {
          previous();
        } else if (x > 2 / 3) {
          next();
        } else {
          setState(() => _controlsVisible = !_controlsVisible);
        }
    }
  }

  bool _handleReaderScrollNotification(
    ScrollNotification notification,
    MangaReaderSettings settings,
  ) {
    if (notification is ScrollUpdateNotification &&
        _controlsVisible &&
        (notification.scrollDelta ?? 0).abs() >
            mangaReaderHideThresholdPixels(settings.readerHideThreshold)) {
      setState(() => _controlsVisible = false);
    }
    return true;
  }

  Future<void> _navigateChapter({required bool next}) async {
    if (_chapterNavigationInProgress ||
        (next ? !_controller.canNext : !_controller.canPrevious)) {
      return;
    }
    _chapterNavigationInProgress = true;
    try {
      if (next) {
        await _controller.nextChapter();
      } else {
        await _controller.previousChapter();
      }
      if (mounted) setState(() => _readerEpoch++);
    } finally {
      _chapterNavigationInProgress = false;
    }
  }

  void _openPreviousChapter() {
    unawaited(_navigateChapter(next: false));
  }

  void _openNextChapter() {
    unawaited(_navigateChapter(next: true));
  }

  void _toggleFullScreen(MangaReaderSettings settings) {
    unawaited(
      ref
          .read(mangaReaderSettingsProvider.notifier)
          .update((value) => value.copyWith(fullScreen: !settings.fullScreen)),
    );
  }

  String _readerModeLabel(BuildContext context, MangaReaderMode mode) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    return switch (mode) {
      MangaReaderMode.vertical => isArabic ? 'عمودي' : 'Vertical',
      MangaReaderMode.pagedLtr =>
        isArabic ? 'من اليسار لليمين' : 'Left to right',
      MangaReaderMode.pagedRtl =>
        isArabic ? 'من اليمين لليسار' : 'Right to left',
      MangaReaderMode.verticalContinuous =>
        isArabic ? 'عمودي مستمر' : 'Vertical continuous',
      MangaReaderMode.webtoon => isArabic ? 'ويب تون' : 'Webtoon',
      MangaReaderMode.horizontalContinuous =>
        isArabic ? 'أفقي مستمر' : 'Horizontal continuous',
      MangaReaderMode.horizontalContinuousRtl =>
        isArabic ? 'أفقي مستمر (RTL)' : 'Horizontal continuous (RTL)',
    };
  }

  Color _backgroundColor(BuildContext context, MangaReaderSettings settings) =>
      switch (settings.background) {
        MangaReaderBackground.black => Colors.black,
        MangaReaderBackground.grey => const Color(0xFF5A5A5A),
        MangaReaderBackground.white => Colors.white,
        MangaReaderBackground.automatic =>
          Theme.of(context).brightness == Brightness.dark
              ? Colors.black
              : const Color(0xFF202020),
      };

  Future<void> _showChapterList() async {
    final chapter = await showModalBottomSheet<MangaChapter>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          itemCount: widget.chapters.length,
          itemBuilder: (context, index) {
            final item = widget.chapters[index];
            final selected = item.id == _controller.currentChapter.id;
            return ListTile(
              selected: selected,
              leading: selected ? const Icon(Icons.menu_book_rounded) : null,
              title: Text(item.name),
              onTap: () => Navigator.of(context).pop(item),
            );
          },
        ),
      ),
    );
    if (chapter == null || !mounted) return;
    await _controller.openChapter(chapter);
    if (mounted) setState(() => _readerEpoch++);
  }

  Future<void> _showQuickSettings() async {
    final readerContext = context;
    await showModalBottomSheet<void>(
      context: readerContext,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: MangaReaderQuickSettings(
          currentMode: _controller.mode,
          mangaId: _readerMangaId,
          onModeChanged: (mode) {
            _setMode(mode, ref.read(mangaReaderSettingsProvider));
          },
          onAutoScrollChanged: (enabled, speed) {
            _setAutoScroll(enabled: enabled, speed: speed);
          },
          onOpenAllSettings: () {
            Navigator.of(sheetContext).pop();
            Navigator.of(readerContext).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const MangaReaderSettingsScreen(),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showImageActions() async {
    if (_controller.pages.isEmpty) return;
    final index = _controller.pageIndex
        .clamp(0, _controller.pages.length - 1)
        .toInt();
    final page = _controller.pages[index];
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => MangaReaderImageActionsSheet(
        isArabic: isArabic,
        onSetCover: () {
          Navigator.of(sheetContext).pop();
          unawaited(_setReaderCover(page));
        },
        onShare: () {
          Navigator.of(sheetContext).pop();
          unawaited(_shareReaderPage(page));
        },
        onSave: () {
          Navigator.of(sheetContext).pop();
          unawaited(_saveReaderPage(page));
        },
      ),
    );
  }

  Future<void> _setReaderCover(MangaPage page) async {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(
          isArabic ? 'استخدام هذه الصورة كغلاف؟' : 'Use this as cover art?',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(isArabic ? 'إلغاء' : 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isArabic ? 'موافق' : 'OK'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final file = await ref
          .read(mangaReaderImageActionsProvider)
          .saveCover(page: page, mangaTitle: widget.manga.title);
      await ref
          .read(mangaReaderCustomCoversProvider.notifier)
          .setCover(widget.manga.url, file.uri.toString());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isArabic ? 'تم تحديث الغلاف' : 'Cover updated')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isArabic ? 'تعذر تحديث الغلاف' : 'Could not update cover',
          ),
        ),
      );
    }
  }

  Future<void> _shareReaderPage(MangaPage page) async {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    try {
      await ref.read(mangaReaderImageActionsProvider).sharePage(
        page: page,
        mangaTitle: widget.manga.title,
        chapterName: _controller.currentChapter.name,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isArabic ? 'تعذرت مشاركة الصورة' : 'Could not share image'),
        ),
      );
    }
  }

  Future<void> _saveReaderPage(MangaPage page) async {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    try {
      final file = await ref.read(mangaReaderImageActionsProvider).savePage(
        page: page,
        mangaTitle: widget.manga.title,
        chapterName: _controller.currentChapter.name,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isArabic ? 'تم حفظ الصورة: ${file.path}' : 'Image saved: ${file.path}',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isArabic ? 'تعذر حفظ الصورة' : 'Could not save image'),
        ),
      );
    }
  }

  MangaChapter? get _nextChapter {
    final index = _controller.currentChapterIndex;
    if (index < 0 || index + 1 >= widget.chapters.length) return null;
    return widget.chapters[index + 1];
  }

  Widget _chapterTransitionPage() => MangaReaderChapterTransitionPage(
    currentChapter: _controller.currentChapter,
    nextChapter: _nextChapter,
    mangaName: widget.manga.title,
    readerMode: _controller.mode,
    onContinue: _controller.canNext ? _openNextChapter : null,
  );

  Widget _readerBody(
    BuildContext context,
    MangaReaderSettings settings,
  ) {
    if (_controller.isLoading) {
      return const Center(child: AppLoadingIndicator());
    }
    if (_controller.error != null) {
      return Center(
        child: Transform.translate(
          offset: const Offset(20, 0),
          child: FilledButton.tonalIcon(
            onPressed: _controller.load,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(
              AppLocalizations.of(context)?.retry ??
                  (Localizations.localeOf(context).languageCode == 'ar'
                      ? 'إعادة المحاولة'
                      : 'Retry'),
            ),
          ),
        ),
      );
    }
    if (_controller.pages.isEmpty) {
      return Center(
        child: Text(
          AppLocalizations.of(context)?.mangaNoPages ??
              (Localizations.localeOf(context).languageCode == 'ar'
                  ? 'لا توجد صفحات'
                  : 'No pages'),
        ),
      );
    }

    final key = ValueKey<String>(
      '${_controller.currentChapter.id}-${_controller.mode.name}-'
      '$_readerEpoch-$_forceDoublePage',
    );
    final doublePage = shouldUseMangaDoublePage(
      settings: settings,
      viewport: MediaQuery.sizeOf(context),
      mode: _controller.mode,
      forceDoublePage: _forceDoublePage,
    );

    return switch (_controller.mode) {
      MangaReaderMode.vertical => MangaPagedReader(
        key: key,
        pages: _controller.pages,
        initialPage: _controller.pageIndex,
        rtl: false,
        scrollDirection: Axis.vertical,
        doublePage: doublePage,
        settings: settings,
        navigationController: _zoomNavigationController,
        trailingPage: _chapterTransitionPage(),
        onTrailingAdvance: _controller.canNext ? _openNextChapter : null,
        onPageChanged: (value) => _onPageChanged(value, settings),
      ),
      MangaReaderMode.pagedLtr => MangaPagedReader(
        key: key,
        pages: _controller.pages,
        initialPage: _controller.pageIndex,
        rtl: false,
        doublePage: doublePage,
        settings: settings,
        navigationController: _zoomNavigationController,
        trailingPage: _chapterTransitionPage(),
        onTrailingAdvance: _controller.canNext ? _openNextChapter : null,
        onPageChanged: (value) => _onPageChanged(value, settings),
      ),
      MangaReaderMode.pagedRtl => MangaPagedReader(
        key: key,
        pages: _controller.pages,
        initialPage: _controller.pageIndex,
        rtl: true,
        doublePage: doublePage,
        settings: settings,
        navigationController: _zoomNavigationController,
        trailingPage: _chapterTransitionPage(),
        onTrailingAdvance: _controller.canNext ? _openNextChapter : null,
        onPageChanged: (value) => _onPageChanged(value, settings),
      ),
      MangaReaderMode.verticalContinuous => MangaContinuousReader(
        key: key,
        pages: _controller.pages,
        initialPage: _controller.pageIndex,
        scrollDirection: Axis.vertical,
        reverse: false,
        doublePage: doublePage,
        settings: settings,
        controller: _continuousController,
        trailingPage: _chapterTransitionPage(),
        onTrailingAdvance: _controller.canNext ? _openNextChapter : null,
        onPageChanged: (value) => _onPageChanged(value, settings),
      ),
      MangaReaderMode.webtoon => MangaWebtoonReader(
        key: key,
        pages: _controller.pages,
        initialPage: _controller.pageIndex,
        settings: settings,
        doublePage: doublePage,
        controller: _continuousController,
        trailingPage: _chapterTransitionPage(),
        onTrailingAdvance: _controller.canNext ? _openNextChapter : null,
        onPageChanged: (value) => _onPageChanged(value, settings),
      ),
      MangaReaderMode.horizontalContinuous => MangaContinuousReader(
        key: key,
        pages: _controller.pages,
        initialPage: _controller.pageIndex,
        scrollDirection: Axis.horizontal,
        reverse: false,
        settings: settings,
        controller: _continuousController,
        trailingPage: _chapterTransitionPage(),
        onTrailingAdvance: _controller.canNext ? _openNextChapter : null,
        onPageChanged: (value) => _onPageChanged(value, settings),
      ),
      MangaReaderMode.horizontalContinuousRtl => MangaContinuousReader(
        key: key,
        pages: _controller.pages,
        initialPage: _controller.pageIndex,
        scrollDirection: Axis.horizontal,
        reverse: true,
        settings: settings,
        controller: _continuousController,
        trailingPage: _chapterTransitionPage(),
        onTrailingAdvance: _controller.canNext ? _openNextChapter : null,
        onPageChanged: (value) => _onPageChanged(value, settings),
      ),
    };
  }

  Widget _topBar(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.ease,
      left: 0,
      right: 0,
      top: _controlsVisible ? 0 : -120,
      child: Material(
        color: Colors.black.withValues(alpha: 0.82),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 64,
            child: Row(
              children: <Widget>[
                if (!appleUsesPersistentLiquidGlassHeader)
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  )
                else
                  const SizedBox(width: 64),
                Expanded(
                  child: ListTile(
                    dense: true,
                    title: Text(
                      widget.manga.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _controller.currentChapter.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Chapters',
                  onPressed: _showChapterList,
                  icon: const Icon(Icons.format_list_numbered_rounded),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _controller.load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context, MangaReaderSettings settings) {
    final max = (_controller.pages.length - 1).clamp(0, 1 << 30).toInt();
    final doublePage = shouldUseMangaDoublePage(
      settings: settings,
      viewport: MediaQuery.sizeOf(context),
      mode: _controller.mode,
      forceDoublePage: _forceDoublePage,
    );
    final currentLabel = mangaReaderPageLabel(
      pageIndex: _controller.pageIndex,
      pageCount: _controller.pages.length,
      doublePage: doublePage,
      singleFirst: settings.doublePageSingleFirstPage,
    );
    final readerDirection =
        _controller.mode.isRtl ? TextDirection.rtl : TextDirection.ltr;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.ease,
      left: 0,
      right: 0,
      bottom: _controlsVisible ? 0 : -150,
      child: Material(
        color: Colors.black.withValues(alpha: 0.86),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                textDirection: readerDirection,
                children: <Widget>[
                  IconButton(
                    onPressed: _controller.canPrevious
                        ? () async {
                            await _controller.previousChapter();
                            if (mounted) setState(() => _readerEpoch++);
                          }
                        : null,
                    icon: const Icon(Icons.skip_previous_rounded),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      currentLabel,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  Expanded(
                    child: Directionality(
                      textDirection: readerDirection,
                      child: Slider(
                        min: 0,
                        max: max.toDouble(),
                        divisions: max <= 0 ? null : max,
                        value: _controller.pageIndex.clamp(0, max).toDouble(),
                        label: currentLabel,
                        onChanged: max <= 0
                            ? null
                            : (value) => _jumpToPage(value.toInt()),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      _controller.pages.length.toString(),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    onPressed: _controller.canNext
                        ? () async {
                            await _controller.nextChapter();
                            if (mounted) setState(() => _readerEpoch++);
                          }
                        : null,
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: <Widget>[
                  PopupMenuButton<MangaReaderMode>(
                    tooltip: 'Reading mode',
                    initialValue: _controller.mode,
                    onSelected: (mode) => _setMode(mode, settings),
                    itemBuilder: (context) => <PopupMenuEntry<MangaReaderMode>>[
                      for (final mode in MangaReaderMode.values)
                        PopupMenuItem<MangaReaderMode>(
                          value: mode,
                          child: Text(_readerModeLabel(context, mode)),
                        ),
                    ],
                    icon: const Icon(Icons.chrome_reader_mode_rounded),
                  ),
                  IconButton(
                    tooltip: 'Crop borders',
                    onPressed: () => ref
                        .read(mangaReaderSettingsProvider.notifier)
                        .update(
                          (s) => s.copyWith(cropBorders: !s.cropBorders),
                        ),
                    icon: Icon(
                      settings.cropBorders
                          ? Icons.crop_free_rounded
                          : Icons.crop_rounded,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Double page',
                    onPressed:
                        _controller.mode == MangaReaderMode.horizontalContinuous ||
                                _controller.mode ==
                                    MangaReaderMode.horizontalContinuousRtl
                            ? null
                            : () => _toggleDoublePage(settings),
                    icon: Icon(
                      _forceDoublePage ||
                              shouldUseMangaDoublePage(
                                settings: settings,
                                viewport: MediaQuery.sizeOf(context),
                                mode: _controller.mode,
                              )
                          ? Icons.menu_book_rounded
                          : Icons.book_outlined,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Reader settings',
                    onPressed: _showQuickSettings,
                    icon: const Icon(Icons.settings_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(mangaReaderSettingsProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncDeviceState(settings);
      _syncAutoScroll(settings);
    });

    final background = _backgroundColor(context, settings);
    final scaffold = Scaffold(
      backgroundColor: background,
      body: MangaReaderKeyboardHandler(
        onEscape: () => Navigator.of(context).maybePop(),
        onFullScreen: () => _toggleFullScreen(settings),
        onPreviousPage: () =>
            _navigateReaderPage(forward: false, settings: settings),
        onNextPage: () =>
            _navigateReaderPage(forward: true, settings: settings),
        onPreviousChapter: _openPreviousChapter,
        onNextChapter: _openNextChapter,
      ).wrapWithKeyboardListener(
        focusNode: _keyboardFocusNode,
        isReverseHorizontal: _controller.mode.isRtl,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) =>
              _handleReaderScrollNotification(notification, settings),
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              fit: StackFit.expand,
              children: <Widget>[
              ColoredBox(
                color: background,
                child: GestureDetector(
                  key: const ValueKey<String>('manga-reader-image-actions-gesture'),
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (details) => _handleTapZone(
                    details,
                    Size(constraints.maxWidth, constraints.maxHeight),
                    settings,
                  ),
                  onLongPress: _showImageActions,
                  child: _readerBody(context, settings),
                ),
              ),
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _flashVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 80),
                  child: ColoredBox(
                    color: settings.flashColor == 1
                        ? Colors.white
                        : settings.flashColor == 2
                        ? Colors.white.withValues(alpha: 0.55)
                        : Colors.black,
                  ),
                ),
              ),
              _topBar(context),
              _bottomBar(context, settings),
              SafeArea(
                minimum: const EdgeInsets.only(bottom: 4),
                child: MangaReaderPageIndicator(
                  visible: !_controlsVisible && settings.showPageNumber,
                  currentPage: _controller.pageIndex + 1,
                  totalPages: _controller.pages.length,
                ),
              ),
              SafeArea(
                child: MangaReaderAutoScrollButton(
                  isContinuousMode: _controller.mode.isContinuous,
                  isUiVisible: _controlsVisible,
                  enabled:
                      settings.autoScrollForManga(_readerMangaId).enabled,
                  isPlaying: _autoScrollRunning,
                  onToggle: () => _toggleAutoScroll(settings),
                ),
              ),
              if (_showNavigationOverlay)
                Positioned.fill(
                  child: MangaReaderNavigationOverlay(
                    navigationLayout: settings.navigationLayout,
                    tappingInversion: settings.tappingInversion,
                    isRtl: _controller.mode.isRtl,
                    onClose: () =>
                        setState(() => _showNavigationOverlay = false),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!appleUsesPersistentLiquidGlassHeader) return scaffold;
    final colors = Theme.of(context).colorScheme;
    return ApplePersistentGlassHeaderScope(
      onBack: _controlsVisible ? () => Navigator.of(context).maybePop() : null,
      backForegroundColor: colors.onSurface,
      backFallbackColor: colors.surfaceContainerHigh,
      // Keep the reader's route registered even while its chrome is hidden so
      // Details favorite/list actions never reappear over the reader.
      trailing: const SizedBox.shrink(),
      trailingButtons: const <AppleLiquidGlassToolbarButton>[],
      child: scaffold,
    );
  }
}

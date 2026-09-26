import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/storage/manga_reading_repository.dart';
import '../../../core/utils/window_controls_inset.dart';
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
import 'widgets/manga_reader_filter_layer.dart';
import 'widgets/manga_reader_image_actions_sheet.dart';
import 'widgets/manga_reader_navigation_overlay.dart';
import 'widgets/manga_reader_page_indicator.dart';
import 'widgets/manga_reader_settings_panel.dart';
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

  /// Keeps the pages as they are when a filter is switched on or off: the
  /// filters wrap the pages in more or fewer layers, and without this the
  /// reader under them would start again and load every page anew.
  final GlobalKey _readerBodyKey = GlobalKey();

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
  bool _settingsPanelOpen = false;
  MangaReaderPanelTab _panelTab = MangaReaderPanelTab.mode;

  /// A short note in the middle of the page — the reading mode as a chapter
  /// opens, or the screen's new turning — gone after a moment.
  String? _toast;
  Timer? _toastTimer;
  List<DeviceOrientation>? _orientationApplied;

  /// Phones and tablets turn; a computer's window does not.
  bool get _canRotate =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// Android hands the volume keys to the app; iOS keeps them.
  bool get _hasVolumeKeys => defaultTargetPlatform == TargetPlatform.android;

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
      if (settings.showReadingMode) {
        _showToast(_readerModeLabel(context, _controller.mode));
      }
    });
  }

  void _showToast(String text) {
    _toastTimer?.cancel();
    setState(() => _toast = text);
    _toastTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _toast = null);
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
    _toastTimer?.cancel();
    if (_orientationApplied?.isNotEmpty == true) {
      // Back to turning with the device, as the rest of the app does.
      unawaited(
        SystemChrome.setPreferredOrientations(const <DeviceOrientation>[])
            .catchError((_) {}),
      );
    }
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
    if (_canRotate) {
      final wanted = mangaReaderOrientations(
        settings.orientationForManga(_readerMangaId),
      );
      if (_orientationApplied == null ||
          !listEquals(_orientationApplied, wanted)) {
        _orientationApplied = wanted;
        unawaited(
          SystemChrome.setPreferredOrientations(wanted).catchError((_) {}),
        );
      }
    }
  }

  /// This manga's own turning, or back to the default with null.
  void _setOrientation(MangaReaderOrientation? orientation) {
    final current = ref.read(mangaReaderSettingsProvider);
    final next = orientation == null
        ? current.withoutMangaOrientation(_readerMangaId)
        : current.withMangaOrientation(_readerMangaId, orientation);
    unawaited(ref.read(mangaReaderSettingsProvider.notifier).setSettings(next));
    _syncDeviceState(next);
  }

  /// The bar's rotate button: with the device, then upright, then on its
  /// side, for this manga.
  void _cycleOrientation(MangaReaderSettings settings) {
    final current = settings.orientationForManga(_readerMangaId);
    final next = MangaReaderOrientation
        .values[(current.index + 1) % MangaReaderOrientation.values.length];
    _setOrientation(next);
    _showToast(_orientationLabel(context, next));
  }

  String _orientationLabel(
    BuildContext context,
    MangaReaderOrientation orientation,
  ) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    return switch (orientation) {
      MangaReaderOrientation.free =>
        isArabic ? 'الشاشة تدور مع الجهاز' : 'Rotates with the device',
      MangaReaderOrientation.portrait => isArabic ? 'الشاشة طولية' : 'Portrait',
      MangaReaderOrientation.landscape =>
        isArabic ? 'الشاشة عرضية' : 'Landscape',
      MangaReaderOrientation.lockedPortrait =>
        isArabic ? 'طولية مقفلة' : 'Locked portrait',
      MangaReaderOrientation.lockedLandscape =>
        isArabic ? 'عرضية مقفلة' : 'Locked landscape',
      MangaReaderOrientation.reversePortrait =>
        isArabic ? 'طولية مقلوبة' : 'Reverse portrait',
    };
  }

  IconData _orientationIcon(MangaReaderOrientation orientation) =>
      switch (orientation) {
        MangaReaderOrientation.free => Icons.screen_rotation_rounded,
        MangaReaderOrientation.portrait ||
        MangaReaderOrientation.lockedPortrait ||
        MangaReaderOrientation.reversePortrait =>
          Icons.stay_current_portrait_rounded,
        MangaReaderOrientation.landscape ||
        MangaReaderOrientation.lockedLandscape =>
          Icons.stay_current_landscape_rounded,
      };

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
    unawaited(ref.read(mangaReaderSettingsProvider.notifier).setSettings(next));
    _syncAutoScroll(next);
  }

  void _toggleAutoScroll(MangaReaderSettings settings) {
    final current = settings.autoScrollForManga(_readerMangaId);
    _setAutoScroll(enabled: !current.enabled, speed: current.speed);
  }

  void _setMode(MangaReaderMode mode, MangaReaderSettings settings) {
    _controller.setMode(mode);
    final next = settings.withMangaMode(_readerMangaId, mode);
    unawaited(ref.read(mangaReaderSettingsProvider.notifier).setSettings(next));
    setState(() {
      _readerEpoch++;
      if (!mode.isContinuous) _autoScrollRunning = false;
    });
    _syncAutoScroll(next);
    if (next.showReadingMode) _showToast(_readerModeLabel(context, mode));
  }

  void _toggleDoublePage(MangaReaderSettings settings) {
    final nextValue = !_forceDoublePage;
    final next = settings.withMangaDoublePage(_readerMangaId, nextValue);
    setState(() => _forceDoublePage = nextValue);
    unawaited(ref.read(mangaReaderSettingsProvider.notifier).setSettings(next));
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
    _flashTimer = Timer(Duration(milliseconds: settings.flashDurationMs), () {
      if (mounted) setState(() => _flashVisible = false);
    });
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
      if (forward && position.extentAfter <= 0.5 && _controller.canNext) {
        _openNextChapter();
        return;
      }
      if (!forward && position.extentBefore <= 0.5 && _controller.canPrevious) {
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
    final invert =
        settings.tappingInversion == 1 || settings.tappingInversion == 3;
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
    final invert =
        settings.tappingInversion == 1 || settings.tappingInversion == 3;
    final rtl = _controller.mode.isRtl;
    final previous = rtl
        ? () => _navigateReaderPage(forward: true, settings: settings)
        : () => _navigateReaderPage(forward: false, settings: settings);
    final next = rtl
        ? () => _navigateReaderPage(forward: false, settings: settings)
        : () => _navigateReaderPage(forward: true, settings: settings);
    return invert ? previous : next;
  }

  void _toggleControls() {
    setState(() {
      _controlsVisible = !_controlsVisible;
      // The panel belongs to the bars: it goes when they do.
      if (!_controlsVisible) _settingsPanelOpen = false;
    });
  }

  void _handleTapZone(
    TapUpDetails details,
    Size size,
    MangaReaderSettings settings,
  ) {
    if (!settings.usePageTapZones || settings.navigationLayout == 5) return;

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
        }
      case 2:
        if (y >= .25) {
          x < .5 ? previous() : next();
        }
      case 3:
        if (x < 1 / 7) {
          previous();
        } else if (x > 6 / 7) {
          next();
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
      setState(() {
        _controlsVisible = false;
        _settingsPanelOpen = false;
      });
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

  String _readerModeLabel(BuildContext context, MangaReaderMode mode) =>
      mangaReaderModeName(
        mode,
        arabic:
            Localizations.localeOf(context).languageCode.toLowerCase() == 'ar',
      );

  /// This manga back on the default reading mode.
  void _useDefaultMode() {
    final current = ref.read(mangaReaderSettingsProvider);
    final next = current.withoutMangaMode(_readerMangaId);
    unawaited(ref.read(mangaReaderSettingsProvider.notifier).setSettings(next));
    final mode = next.modeForManga(_readerMangaId);
    _controller.setMode(mode);
    setState(() {
      _readerEpoch++;
      if (!mode.isContinuous) _autoScrollRunning = false;
    });
    _syncAutoScroll(next);
    if (next.showReadingMode) _showToast(_readerModeLabel(context, mode));
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

  void _toggleSettingsPanel({
    MangaReaderPanelTab tab = MangaReaderPanelTab.mode,
  }) => setState(() {
    _panelTab = tab;
    _settingsPanelOpen = !_settingsPanelOpen;
  });

  /// The panel the settings button opens, floating above the bottom bar,
  /// with a scrim to close it by clicking anywhere else.
  List<Widget> _settingsPanel(
    BuildContext context,
    MangaReaderSettings settings,
  ) {
    if (!_settingsPanelOpen || !_controlsVisible) return const <Widget>[];
    final doublePage =
        _forceDoublePage ||
        shouldUseMangaDoublePage(
          settings: settings,
          viewport: MediaQuery.sizeOf(context),
          mode: _controller.mode,
        );
    return <Widget>[
      Positioned.fill(
        child: GestureDetector(
          key: const ValueKey<String>('manga-reader-settings-scrim'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggleSettingsPanel(),
        ),
      ),
      // Mihon's sheet: up from the foot of the screen, over the bars.
      Positioned(
        left: 12,
        right: 12,
        bottom: 12 + MediaQuery.paddingOf(context).bottom,
        child: Align(
          alignment: Alignment.bottomCenter,
          // The sheet's own scrolling stays with it: the reader hides its
          // bars, and the sheet with them, when the pages scroll.
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) => true,
            child: MangaReaderSettingsPanel(
              settings: settings,
              mode: _controller.mode,
              doublePage: doublePage,
              initialTab: _panelTab,
              modeIsDefault: !settings.hasOwnMode(_readerMangaId),
              onDefaultMode: _useDefaultMode,
              orientation: settings.hasOwnOrientation(_readerMangaId)
                  ? settings.orientationForManga(_readerMangaId)
                  : null,
              onOrientation: _canRotate ? _setOrientation : null,
              showVolumeKeys: _hasVolumeKeys,
              touchDevice: _canRotate,
              onMode: (mode) =>
                  _setMode(mode, ref.read(mangaReaderSettingsProvider)),
              onDoublePage: (value) {
                if (value != _forceDoublePage) {
                  _toggleDoublePage(ref.read(mangaReaderSettingsProvider));
                }
              },
              onUpdate: (change) =>
                  ref.read(mangaReaderSettingsProvider.notifier).update(change),
              onOpenAllSettings: () {
                setState(() => _settingsPanelOpen = false);
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const MangaReaderSettingsScreen(),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ];
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
      await ref
          .read(mangaReaderImageActionsProvider)
          .sharePage(
            page: page,
            mangaTitle: widget.manga.title,
            chapterName: _controller.currentChapter.name,
          );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isArabic ? 'تعذرت مشاركة الصورة' : 'Could not share image',
          ),
        ),
      );
    }
  }

  Future<void> _saveReaderPage(MangaPage page) async {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    try {
      final file = await ref
          .read(mangaReaderImageActionsProvider)
          .savePage(
            page: page,
            mangaTitle: widget.manga.title,
            chapterName: _controller.currentChapter.name,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isArabic
                ? 'تم حفظ الصورة: ${file.path}'
                : 'Image saved: ${file.path}',
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

  Widget _readerBody(BuildContext context, MangaReaderSettings settings) {
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
        onDoubleTap: _toggleControls,
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
        onDoubleTap: _toggleControls,
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
        onDoubleTap: _toggleControls,
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
        onDoubleTap: _toggleControls,
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
        onDoubleTap: _toggleControls,
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
        onDoubleTap: _toggleControls,
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
        onDoubleTap: _toggleControls,
        trailingPage: _chapterTransitionPage(),
        onTrailingAdvance: _controller.canNext ? _openNextChapter : null,
        onPageChanged: (value) => _onPageChanged(value, settings),
      ),
    };
  }

  /// A floating piece of the reader's chrome: rounded, in the bars' colour.
  Widget _pill(BuildContext context, {Key? key, required Widget child}) =>
      Material(
        key: key,
        color: _barColor(context),
        elevation: 3,
        shadowColor: Colors.black54,
        borderRadius: BorderRadius.circular(99),
        clipBehavior: Clip.antiAlias,
        child: child,
      );

  /// The top of the floating layout: the manga and chapter in one pill,
  /// the chapter list and refresh in another, clear of the window's own
  /// buttons in whichever corner they are.
  Widget _topBar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top + 8;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.ease,
      left: 8 + windowControlsLeadingInset,
      right: 8 + windowControlsTrailingInset,
      top: _controlsVisible ? top : -120,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: _controlsVisible ? 1 : 0,
        child: IconTheme(
          data: IconThemeData(color: colors.onSurface),
          child: Row(
            key: const ValueKey<String>('manga-reader-top-bar'),
            // The title on the left with its back arrow, the tools on the
            // right, in every language: the arrow points the way it leads.
            textDirection: TextDirection.ltr,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Flexible(
                child: _pill(
                  context,
                  key: const ValueKey<String>('manga-reader-top-chrome'),
                  child: Row(
                    textDirection: TextDirection.ltr,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (!appleUsesPersistentLiquidGlassHeader)
                        IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        )
                      else
                        const SizedBox(width: 56, height: 48),
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 18),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                widget.manga.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.onSurface,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                _controller.currentChapter.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _pill(
                context,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
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
            ],
          ),
        ),
      ),
    );
  }

  /// The bars' colours, from the theme rather than a fixed black, so they
  /// match the rest of the app in every theme.
  Color _barColor(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerLow.withValues(alpha: 0.94);

  /// The page slider in the theme's accent, whichever way it runs.
  Widget _themedSlider(BuildContext context, Widget slider) {
    final colors = Theme.of(context).colorScheme;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: colors.primary,
        inactiveTrackColor: colors.primary.withValues(alpha: 0.22),
        thumbColor: colors.primary,
        overlayColor: colors.primary.withValues(alpha: 0.12),
        valueIndicatorColor: colors.primary,
        valueIndicatorTextStyle: TextStyle(color: colors.onPrimary),
        activeTickMarkColor: colors.onPrimary.withValues(alpha: 0.5),
        inactiveTickMarkColor: colors.primary.withValues(alpha: 0.4),
      ),
      child: slider,
    );
  }

  /// The bars at the foot, and Mihon's vertical navigator down the side in
  /// the modes that use it.
  List<Widget> _bottomBars(BuildContext context, MangaReaderSettings settings) {
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
    final readerDirection = _controller.mode.isRtl
        ? TextDirection.rtl
        : TextDirection.ltr;
    final colors = Theme.of(context).colorScheme;
    final vertical = settings.usesVerticalBar(_controller.mode);
    // Mihon's chapter buttons are round, at either end of the slider.
    final round = IconButton.styleFrom(
      backgroundColor: colors.surfaceContainerHighest,
      foregroundColor: colors.onSurface,
    );

    final previous = IconButton(
      key: const ValueKey<String>('manga-reader-previous-chapter'),
      style: round,
      tooltip: Localizations.localeOf(context).languageCode == 'ar'
          ? 'الفصل السابق'
          : 'Previous chapter',
      onPressed: _controller.canPrevious
          ? () async {
              await _controller.previousChapter();
              if (mounted) setState(() => _readerEpoch++);
            }
          : null,
      icon: Icon(
        vertical
            ? Icons.keyboard_double_arrow_up_rounded
            : Icons.skip_previous_rounded,
      ),
    );
    final next = IconButton(
      key: const ValueKey<String>('manga-reader-next-chapter'),
      style: round,
      tooltip: Localizations.localeOf(context).languageCode == 'ar'
          ? 'الفصل التالي'
          : 'Next chapter',
      onPressed: _controller.canNext
          ? () async {
              await _controller.nextChapter();
              if (mounted) setState(() => _readerEpoch++);
            }
          : null,
      icon: Icon(
        vertical
            ? Icons.keyboard_double_arrow_down_rounded
            : Icons.skip_next_rounded,
      ),
    );
    final slider = _themedSlider(
      context,
      Slider(
        min: 0,
        max: max.toDouble(),
        divisions: max <= 0 ? null : max,
        value: _controller.pageIndex.clamp(0, max).toDouble(),
        label: currentLabel,
        onChanged: max <= 0 ? null : (value) => _jumpToPage(value.toInt()),
      ),
    );
    // One button for every reader setting, as Harbor has it: the mode,
    // direction, fit and background are in the panel it opens rather than in
    // a row of icons of their own.
    final settingsButton = IconButton(
      key: const ValueKey<String>('manga-reader-settings-button'),
      tooltip: Localizations.localeOf(context).languageCode == 'ar'
          ? 'إعدادات القارئ'
          : 'Reader settings',
      isSelected: _settingsPanelOpen,
      onPressed: () => _toggleSettingsPanel(),
      icon: const Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings_rounded, color: colors.primary),
    );
    final labelStyle = TextStyle(color: colors.onSurface, fontSize: 13);

    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    final orientation = settings.orientationForManga(_readerMangaId);
    // Mihon's row under the slider: the mode, the screen's turning, borders
    // cropped or not, and the rest of the settings.
    final actions = <Widget>[
      PopupMenuButton<MangaReaderMode>(
        key: const ValueKey<String>('manga-reader-bar-mode'),
        tooltip: isArabic ? 'وضع القراءة' : 'Reading mode',
        icon: const Icon(Icons.auto_stories_outlined),
        initialValue: _controller.mode,
        onSelected: (mode) {
          if (mode != _controller.mode) {
            _setMode(mode, ref.read(mangaReaderSettingsProvider));
          }
        },
        itemBuilder: (context) => <PopupMenuEntry<MangaReaderMode>>[
          for (final mode in MangaReaderMode.values)
            CheckedPopupMenuItem<MangaReaderMode>(
              key: ValueKey<String>('manga-reader-bar-mode-${mode.name}'),
              value: mode,
              checked: mode == _controller.mode,
              child: Text(_readerModeLabel(context, mode)),
            ),
        ],
      ),
      if (_canRotate)
        IconButton(
          key: const ValueKey<String>('manga-reader-bar-rotate'),
          tooltip: _orientationLabel(context, orientation),
          onPressed: () => _cycleOrientation(settings),
          icon: Icon(_orientationIcon(orientation)),
        ),
      IconButton(
        key: const ValueKey<String>('manga-reader-bar-crop'),
        tooltip: isArabic ? 'قص الحواف' : 'Crop borders',
        isSelected: settings.cropBorders,
        onPressed: () => ref
            .read(mangaReaderSettingsProvider.notifier)
            .update((s) => s.copyWith(cropBorders: !s.cropBorders)),
        icon: const Icon(Icons.crop_rounded),
        selectedIcon: Icon(Icons.crop_rounded, color: colors.primary),
      ),
      settingsButton,
    ];

    final media = MediaQuery.of(context);
    final pageSlider = Row(
      key: const ValueKey<String>('manga-reader-page-pill'),
      textDirection: readerDirection,
      children: <Widget>[
        SizedBox(
          width: 40,
          child: Text(
            currentLabel,
            textAlign: TextAlign.center,
            style: labelStyle,
          ),
        ),
        Expanded(
          child: Directionality(textDirection: readerDirection, child: slider),
        ),
        SizedBox(
          width: 40,
          child: Text(
            _controller.pages.length.toString(),
            textAlign: TextAlign.center,
            style: labelStyle,
          ),
        ),
      ],
    );
    Widget divider({required bool vertical}) => Container(
      width: vertical ? 28 : 1,
      height: vertical ? 1 : 28,
      margin: const EdgeInsets.all(6),
      color: colors.outlineVariant,
    );

    if (vertical) {
      // The dock down the side, in the modes picked for it: the chapter
      // buttons at its ends of the slider, then the tools.
      final top = media.padding.top + 72;
      final foot = media.padding.bottom + 12;
      final room = (media.size.height - top - foot).clamp(200.0, 4000.0);
      final minimum = room < 420.0 ? room : 420.0;
      final height = (room * settings.verticalBarHeight / 100).clamp(
        minimum,
        room,
      );
      final left = settings.verticalBarLeft;
      final offset = _controlsVisible ? 10.0 : -90.0;
      return <Widget>[
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.ease,
          top: top + (room - height) / 2,
          height: height,
          width: 56,
          left: left ? offset : null,
          right: left ? null : offset,
          child: IconTheme(
            data: IconThemeData(color: colors.onSurface),
            child: Material(
              key: const ValueKey<String>('manga-reader-page-bar-vertical'),
              color: _barColor(context),
              elevation: 3,
              shadowColor: Colors.black54,
              borderRadius: BorderRadius.circular(99),
              child: Column(
                children: <Widget>[
                  const SizedBox(height: 6),
                  previous,
                  Text(currentLabel, style: labelStyle),
                  // Top to bottom in every language: page one at the top.
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 1,
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: slider,
                      ),
                    ),
                  ),
                  Text(_controller.pages.length.toString(), style: labelStyle),
                  next,
                  divider(vertical: true),
                  ...actions,
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        ),
      ];
    }

    // The dock at the foot: one capsule on a wide window, two rows in a
    // rounded card on a narrow one.
    final wide = media.size.width >= 720;
    final dock = wide
        ? Row(
            children: <Widget>[
              Expanded(
                child: Row(
                  textDirection: readerDirection,
                  children: <Widget>[
                    previous,
                    Expanded(child: pageSlider),
                    next,
                  ],
                ),
              ),
              divider(vertical: false),
              ...actions,
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                textDirection: readerDirection,
                children: <Widget>[
                  previous,
                  Expanded(child: pageSlider),
                  next,
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: actions,
              ),
            ],
          );
    return <Widget>[
      AnimatedPositioned(
        duration: const Duration(milliseconds: 300),
        curve: Curves.ease,
        left: 12,
        right: 12,
        bottom: _controlsVisible ? media.padding.bottom + 12 : -220,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: IconTheme(
              data: IconThemeData(color: colors.onSurface),
              child: Material(
                key: const ValueKey<String>('manga-reader-page-bar'),
                color: _barColor(context),
                elevation: 3,
                shadowColor: Colors.black54,
                borderRadius: BorderRadius.circular(wide ? 99 : 28),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: dock,
                ),
              ),
            ),
          ),
        ),
      ),
    ];
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
      body:
          MangaReaderKeyboardHandler(
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
            volumeKeys: _hasVolumeKeys && settings.readWithVolumeKeys,
            volumeKeysInverted: settings.readWithVolumeKeysInverted,
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
                        key: const ValueKey<String>(
                          'manga-reader-image-actions-gesture',
                        ),
                        behavior: HitTestBehavior.translucent,
                        onTapUp: (details) => _handleTapZone(
                          details,
                          Size(constraints.maxWidth, constraints.maxHeight),
                          settings,
                        ),
                        onDoubleTap: _toggleControls,
                        onLongPress: settings.showActionsOnLongTap
                            ? _showImageActions
                            : _toggleControls,
                        onSecondaryTap: _showImageActions,
                        child: MangaReaderFilterLayer(
                          settings: settings,
                          child: KeyedSubtree(
                            key: _readerBodyKey,
                            child: _readerBody(context, settings),
                          ),
                        ),
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
                    ..._bottomBars(context, settings),
                    ..._settingsPanel(context, settings),
                    MangaReaderPageIndicator(
                      visible: !_controlsVisible && settings.showPageNumber,
                      currentPage: _controller.pageIndex + 1,
                      totalPages: _controller.pages.length,
                    ),
                    SafeArea(
                      child: MangaReaderAutoScrollButton(
                        isContinuousMode: _controller.mode.isContinuous,
                        isUiVisible: _controlsVisible,
                        enabled: settings
                            .autoScrollForManga(_readerMangaId)
                            .enabled,
                        isPlaying: _autoScrollRunning,
                        onToggle: () => _toggleAutoScroll(settings),
                      ),
                    ),
                    IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _toast == null ? 0 : 1,
                        duration: const Duration(milliseconds: 200),
                        child: Center(
                          child: _toast == null
                              ? const SizedBox.shrink()
                              : Container(
                                  key: const ValueKey<String>(
                                    'manga-reader-toast',
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.75),
                                    borderRadius: BorderRadius.circular(99),
                                  ),
                                  child: Text(
                                    _toast!,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                        ),
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

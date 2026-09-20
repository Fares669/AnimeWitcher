import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/storage/manga_reading_repository.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import '../../../shared/widgets/loading_indicator.dart';
import 'manga_reader_controller.dart';
import 'widgets/manga_paged_reader.dart';
import 'widgets/manga_reader_controls.dart';
import 'widgets/manga_webtoon_reader.dart';

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

class _MangaReaderScreenState extends ConsumerState<MangaReaderScreen> {
  late final MangaReaderController _controller;

  @override
  void initState() {
    super.initState();
    final provider = _resolveProvider();
    _controller = MangaReaderController(
      provider: provider,
      progressRepository: ref.read(mangaReadingRepositoryProvider),
      manga: widget.manga,
      chapter: widget.chapter,
      chapters: widget.chapters,
      localChapterDirectory: widget.localChapterDirectory,
    );
    _controller.load();
  }

  AnimeWitcherProvider _resolveProvider() {
    final manager = ref.read(extensionManagerProvider.notifier);
    final requested = widget.manga.provider?.trim() ?? '';
    final selected = requested.isEmpty ? null : manager.getProvider(requested);
    if (selected != null) return selected;
    for (final provider in manager.getAllProviders()) {
      if (provider.supportedTypes.contains(ProviderType.manga)) {
        return provider;
      }
    }
    throw StateError('No Manga provider is available.');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final scaffold = Scaffold(
          appBar: MangaReaderControls(
            chapterLabel: _controller.currentChapter.name,
            pageIndex: _controller.pageIndex,
            pageCount: _controller.pages.length,
            mode: _controller.mode,
            onModeChanged: _controller.setMode,
            onPreviousChapter: _controller.canPrevious
                ? () => _controller.previousChapter()
                : null,
            onNextChapter: _controller.canNext
                ? () => _controller.nextChapter()
                : null,
          ),
          body: _body(context),
        );

        if (!appleUsesPersistentLiquidGlassHeader) return scaffold;
        final colors = Theme.of(context).colorScheme;
        return ApplePersistentGlassHeaderScope(
          onBack: () => Navigator.of(context).maybePop(),
          backForegroundColor: colors.onSurface,
          backFallbackColor: colors.surfaceContainerHigh,
          trailingButtons: const <AppleLiquidGlassToolbarButton>[],
          child: scaffold,
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    if (_controller.isLoading) {
      return const Center(child: AppLoadingIndicator());
    }
    if (_controller.error != null) {
      return Center(
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
      _controller.currentChapter.id + '-' + _controller.mode.name,
    );
    return switch (_controller.mode) {
      MangaReaderMode.webtoon => MangaWebtoonReader(
        key: key,
        pages: _controller.pages,
        initialPage: _controller.pageIndex,
        onPageChanged: _controller.setPageIndex,
      ),
      MangaReaderMode.pagedLtr => MangaPagedReader(
        key: key,
        pages: _controller.pages,
        initialPage: _controller.pageIndex,
        rtl: false,
        onPageChanged: _controller.setPageIndex,
      ),
      MangaReaderMode.pagedRtl => MangaPagedReader(
        key: key,
        pages: _controller.pages,
        initialPage: _controller.pageIndex,
        rtl: true,
        onPageChanged: _controller.setPageIndex,
      ),
    };
  }
}

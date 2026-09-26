import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/animewitcher_comment_models.dart';
import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/storage/library_category.dart';
import '../../../core/utils/image_fallbacks.dart';
import '../../../core/storage/manga_reading_repository.dart';
import '../../../core/utils/localized_text.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../core/utils/window_controls_inset.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import '../../../shared/widgets/expandable_text.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../details/presentation/widgets/details_desktop_hero.dart';
import '../../details/presentation/widgets/details_hero_actions.dart';
import '../../details/presentation/widgets/details_rating_actions.dart';
import '../../library/presentation/download_delete_confirmation.dart';
import '../../library/presentation/downloads_provider.dart';
import '../../library/presentation/library_auth.dart';
import '../../library/presentation/library_provider.dart';
import '../../settings/presentation/account_screen.dart';
import '../reader/manga_reader_cover_provider.dart';
import 'manga_details_controller.dart';
import 'manga_details_state.dart';
import 'manga_resume_chapter.dart';
import 'widgets/manga_chapter_list.dart';
import 'widgets/manga_information_section.dart';

@visibleForTesting
MultimediaItem mangaDetailsItemWithCustomCover(
  MultimediaItem baseItem,
  String customCover,
) {
  final cover = customCover.trim();
  return cover.isEmpty
      ? baseItem
      : baseItem.copyWith(posterUrl: cover, fullPosterUrl: cover);
}

/// The genres, split out of however the source joined them and without
/// repeats.
List<String> _mangaGenres(MultimediaItem item) {
  final seen = <String>{};
  final output = <String>[];
  for (final raw in item.tags ?? const <String>[]) {
    for (final part in raw.split(RegExp(r'[,،|/]'))) {
      final value = part.trim();
      if (value.isEmpty) continue;
      if (seen.add(value.toLowerCase())) output.add(value);
    }
  }
  return output;
}

class MangaDetailsScreen extends ConsumerStatefulWidget {
  const MangaDetailsScreen({
    super.key,
    required this.item,
    this.onOpenChapter,
    this.onDownloadChapter,
  });

  final MultimediaItem item;
  final ValueChanged<MangaChapter>? onOpenChapter;
  final ValueChanged<MangaChapter>? onDownloadChapter;

  @override
  ConsumerState<MangaDetailsScreen> createState() => _MangaDetailsScreenState();
}

class _MangaDetailsScreenState extends ConsumerState<MangaDetailsScreen> {
  static const String _removeLibraryAction = '__remove_from_library__';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(mangaDetailsControllerProvider(widget.item.url).notifier)
          .load(widget.item);
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  String _categoryLabel(BuildContext context, LibraryCategory category) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return switch (category) {
      LibraryCategory.favorite => ar ? 'المفضلة' : 'Favorites',
      LibraryCategory.watching => ar ? 'أقرأها حاليًا' : 'Reading',
      LibraryCategory.continueLater => ar ? 'أكملها لاحقًا' : 'Continue later',
      LibraryCategory.planToWatch => ar ? 'أرغب بقراءتها' : 'Plan to read',
      LibraryCategory.completed => ar ? 'تمت قراءتها' : 'Completed',
      LibraryCategory.notInterested =>
        ar ? 'لا أرغب بقراءتها' : 'Not interested',
    };
  }

  IconData _categoryIcon(LibraryCategory category) => switch (category) {
    LibraryCategory.favorite => Icons.favorite_rounded,
    LibraryCategory.watching => Icons.menu_book_rounded,
    LibraryCategory.continueLater => Icons.pause_circle_filled_rounded,
    LibraryCategory.planToWatch => Icons.schedule_rounded,
    LibraryCategory.completed => Icons.check_circle_rounded,
    LibraryCategory.notInterested => Icons.block_rounded,
  };

  String _categorySystemImage(LibraryCategory category) => switch (category) {
    LibraryCategory.favorite => 'heart.fill',
    LibraryCategory.watching => 'book.fill',
    LibraryCategory.continueLater => 'pause.circle.fill',
    LibraryCategory.planToWatch => 'clock',
    LibraryCategory.completed => 'checkmark.circle.fill',
    LibraryCategory.notInterested => 'xmark.circle.fill',
  };

  List<AppleNativeMenuItem> _categoryMenuItems(
    BuildContext context,
    MultimediaItem item,
    LibraryCategory? current,
  ) {
    final items = <AppleNativeMenuItem>[
      for (final category in LibraryCategory.primaryValues)
        AppleNativeMenuItem(
          value: category.storageKey,
          label: _categoryLabel(context, category),
          systemImage: _categorySystemImage(category),
          icon: _categoryIcon(category),
        ),
    ];
    if (current != null) {
      items.add(
        AppleNativeMenuItem(
          value: _removeLibraryAction,
          label: Localizations.localeOf(context).languageCode == 'ar'
              ? 'إزالة من القائمة'
              : 'Remove from list',
          systemImage: 'trash',
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      );
    }
    return items;
  }

  Future<void> _setLibraryCategory(
    dynamic libraryNotifier,
    MultimediaItem item,
    String value,
  ) async {
    if (libraryNotifier == null) return;
    if (!await _ensureSignedInForLibrary(context)) return;
    if (value == _removeLibraryAction) {
      await libraryNotifier.clearItemCategory(item.url, manga: true);
      return;
    }
    for (final category in LibraryCategory.primaryValues) {
      if (category.storageKey == value) {
        await libraryNotifier.addItem(item, category: category);
        return;
      }
    }
  }

  List<AppleLiquidGlassToolbarButton> _headerButtons(
    BuildContext context,
    MultimediaItem item, {
    required dynamic libraryNotifier,
    required bool isFavorite,
    required LibraryCategory? currentCategory,
  }) {
    const favoriteRed = Color(0xFFFF3B30);
    final colors = Theme.of(context).colorScheme;
    final foreground = colors.onSurface;
    return <AppleLiquidGlassToolbarButton>[
      AppleLiquidGlassToolbarButton(
        tooltip: isFavorite
            ? (Localizations.localeOf(context).languageCode == 'ar'
                  ? 'إزالة من المفضلة'
                  : 'Remove favorite')
            : (Localizations.localeOf(context).languageCode == 'ar'
                  ? 'إضافة إلى المفضلة'
                  : 'Add to favorites'),
        icon: isFavorite
            ? Icons.favorite_rounded
            : Icons.favorite_border_rounded,
        systemImage: isFavorite ? 'heart.fill' : 'heart',
        color: isFavorite ? favoriteRed : foreground,
        onPressed: libraryNotifier == null
            ? null
            : () async {
                if (!await _ensureSignedInForLibrary(context)) return;
                await libraryNotifier.setFavorite(item, !isFavorite);
              },
      ),
      AppleLiquidGlassToolbarButton(
        tooltip: Localizations.localeOf(context).languageCode == 'ar'
            ? 'اختر قائمة'
            : 'Choose list',
        icon: currentCategory == null
            ? Icons.bookmark_border_rounded
            : _categoryIcon(currentCategory),
        systemImage: currentCategory == null
            ? 'bookmark'
            : _categorySystemImage(currentCategory),
        color: currentCategory == null ? foreground : colors.primary,
        menuTintColor: colors.primary,
        selectedMenuValue: currentCategory?.storageKey,
        menuItems: _categoryMenuItems(context, item, currentCategory),
        onMenuSelected: libraryNotifier == null
            ? null
            : (value) => _setLibraryCategory(libraryNotifier, item, value),
        onPressed: null,
      ),
    ];
  }

  Future<bool> _ensureSignedInForLibrary(BuildContext context) async {
    if (ref.read(animeWitcherAccountServiceProvider).isSignedIn) {
      return true;
    }
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    ref
        .read(notificationServiceProvider)
        .showInfo(
          librarySignInRequiredMessage(isArabic: isArabic),
          icon: Icons.lock_outline_rounded,
          duration: const Duration(seconds: 3),
        );
    if (!context.mounted) return false;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => const AnimeWitcherAccountScreen(),
      ),
    );
    return ref.read(animeWitcherAccountServiceProvider).isSignedIn;
  }

  Future<void> _rateManga(MultimediaItem item) async {
    final service = ref.read(animeWitcherAccountServiceProvider);
    if (!service.isSignedIn) {
      ref
          .read(notificationServiceProvider)
          .showInfo(
            Localizations.localeOf(context).languageCode == 'ar'
                ? 'يجب تسجيل الدخول'
                : 'Sign in to rate',
          );
      return;
    }

    final mangaId = animeWitcherMangaIdFromItem(item);
    if (mangaId.isEmpty) return;
    int initial = 0;
    try {
      initial = await service.loadMangaUserRating(mangaId) ?? 0;
    } catch (_) {}
    if (!mounted) return;

    final selected = await showAnimeRatingDialog(
      context,
      initialRating: initial,
    );
    if (selected == null) return;
    try {
      if (selected == 0) {
        await service.clearMangaUserRating(mangaId);
      } else {
        await service.saveMangaUserRating(mangaId, selected);
      }
    } catch (_) {
      ref
          .read(notificationServiceProvider)
          .showError(
            Localizations.localeOf(context).languageCode == 'ar'
                ? 'تعذر حفظ التقييم'
                : 'Could not save rating',
          );
    }
  }

  Future<void> _openChapter(
    MultimediaItem item,
    MangaChapter chapter,
    List<MangaChapter> chapters,
  ) async {
    List<DownloadItem> downloads;
    try {
      downloads = await ref.read(downloadsProvider.future);
    } catch (_) {
      downloads = const <DownloadItem>[];
    }
    if (!mounted) return;

    final completedDownload = completedMangaChapterDownload(downloads, chapter);
    MangaReaderRoute(
      $extra: MangaReaderRouteExtra(
        manga: item,
        chapter: chapter,
        chapters: chapters,
        localChapterDirectory: completedDownload?.destinationPath,
      ),
    ).push<void>(context);
  }

  Future<void> _showPoster(MultimediaItem item) async {
    final url =
        AppImageFallbacks.poster(item.fullPosterUrl ?? item.posterUrl) ?? '';
    if (url.isEmpty) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (dialogContext) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(dialogContext).pop(),
        child: Material(
          color: Colors.black,
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Center(
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                errorWidget: (_, _, _) =>
                    const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The bare bar the anime page uses on a wide window: one back button
  /// floating over the artwork, and nothing else, since the actions sit in
  /// the hero under the title.
  PreferredSizeWidget _wideAppBar(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: false,
          leadingWidth: appleUsesPersistentLiquidGlassHeader ? 0 : 64,
          leading: appleUsesPersistentLiquidGlassHeader
              ? null
              : Padding(
                  padding: EdgeInsets.only(
                    left: 8 + windowControlsLeadingInset,
                  ),
                  child: AppleLiquidGlassBackButton(
                    size: 46,
                    foregroundColor: theme.colorScheme.onSurface,
                    fallbackColor: isDark ? Colors.black45 : Colors.white54,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
          actions: const <Widget>[],
        ),
      ),
    );
  }

  /// The white read pill: the chapter the reader is up to, named.
  Widget _readPill(
    BuildContext context,
    List<MangaChapter>? chapters,
    void Function(MangaChapter chapter) open,
  ) {
    ref.watch(mangaReadingRevisionProvider);
    final repository = ref.watch(mangaReadingRepositoryProvider);
    final target = chapters == null
        ? null
        : mangaResumeTarget(
            chapters,
            (chapter) => repository.get(chapter.mangaId, chapter.id),
          );
    final chapterName = target?.chapter.name ?? '';
    final label = switch (target?.kind) {
      null => appText(context, english: 'Read', arabic: 'اقرأ'),
      MangaResumeKind.start => appText(
        context,
        english: 'Start reading',
        arabic: 'ابدأ القراءة',
      ),
      MangaResumeKind.resume => appText(
        context,
        english: 'Continue · $chapterName',
        arabic: 'تابع · $chapterName',
      ),
      MangaResumeKind.next => appText(
        context,
        english: 'Read · $chapterName',
        arabic: 'اقرأ · $chapterName',
      ),
    };

    // White on the artwork like the anime page's play pill: the one control
    // in the row that is not glass.
    const background = Color(0xFFF2F3F5);
    const foreground = Color(0xFF101114);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        key: const ValueKey<String>('manga-read-pill'),
        color: target != null ? background : background.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(kDetailsHeroActionHeight / 2),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: target == null ? null : () => open(target.chapter),
          child: SizedBox(
            height: kDetailsHeroActionHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.menu_book_rounded,
                    size: 22,
                    color: foreground,
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: foreground,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The row under the title, in the anime page's order: read, the list it
  /// is in, then rating and favourite as round glass buttons.
  Widget _heroActions(
    BuildContext context,
    MultimediaItem item, {
    required List<MangaChapter>? chapters,
    required void Function(MangaChapter chapter) open,
    required dynamic libraryNotifier,
    required bool isFavorite,
    required LibraryCategory? currentCategory,
  }) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fallback = isDark ? Colors.black45 : Colors.white54;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        _readPill(context, chapters, open),
        PopupMenuButton<String>(
          tooltip: appText(
            context,
            english: 'Choose list',
            arabic: 'اختر قائمة',
          ),
          padding: EdgeInsets.zero,
          offset: const Offset(0, 8),
          color: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          shape: const RoundedRectangleBorder(),
          enabled: libraryNotifier != null,
          itemBuilder: (menuContext) => <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              enabled: false,
              padding: EdgeInsets.zero,
              child: BlurredMenuPanel(
                items: _categoryMenuItems(context, item, currentCategory),
                selectedValue: currentCategory?.storageKey ?? '',
                tint: colors.onSurface,
                fallbackIcon: Icons.bookmark_border_rounded,
                onPick: (value) {
                  Navigator.of(menuContext).pop();
                  unawaited(_setLibraryCategory(libraryNotifier, item, value));
                },
              ),
            ),
          ],
          child: DetailsHeroPill(
            fallbackColor: fallback,
            label: currentCategory == null
                ? appText(context, english: 'Add to list', arabic: 'أضف لقائمة')
                : _categoryLabel(context, currentCategory),
            icon: currentCategory == null
                ? Icons.bookmark_border_rounded
                : _categoryIcon(currentCategory),
            selected: currentCategory != null,
            trailing: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: currentCategory != null
                  ? colors.primary
                  : colors.onSurface,
            ),
          ),
        ),
        DetailsHeroIconButton(
          icon: Icons.star_outline_rounded,
          tooltip: appText(context, english: 'Rate this', arabic: 'قيّم'),
          foregroundColor: colors.onSurface,
          fallbackColor: fallback,
          onPressed: () => _rateManga(item),
        ),
        DetailsHeroIconButton(
          icon: isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          tooltip: isFavorite
              ? appText(
                  context,
                  english: 'Remove favorite',
                  arabic: 'إزالة من المفضلة',
                )
              : appText(
                  context,
                  english: 'Add to favorites',
                  arabic: 'إضافة إلى المفضلة',
                ),
          foregroundColor: isFavorite
              ? const Color(0xFFFF3B30)
              : colors.onSurface,
          fallbackColor: fallback,
          onPressed: () async {
            if (libraryNotifier == null) return;
            if (!await _ensureSignedInForLibrary(context)) return;
            await libraryNotifier.setFavorite(item, !isFavorite);
          },
        ),
      ],
    );
  }

  /// The synopsis and genres as they read under the hero's buttons: no card
  /// around them, the genres in the same glass as the buttons.
  Widget _heroStory(BuildContext context, MultimediaItem item) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final description = (item.description ?? '').trim();
    final genres = _mangaGenres(item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ExpandableText(
          text: description.isEmpty
              ? (l10n?.noDescription ??
                    appText(
                      context,
                      english: 'No description',
                      arabic: 'لا يوجد وصف',
                    ))
              : description,
          maxLines: 4,
          toggleColor: colors.onSurface,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colors.onSurface.withValues(alpha: 0.86),
            height: 1.6,
          ),
        ),
        if (genres.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: <Widget>[
              for (final genre in genres)
                Container(
                  key: ValueKey<String>('manga-genre-$genre'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: ShapeDecoration(
                    color: kDetailsHeroGlassFallback,
                    shape: StadiumBorder(
                      side: BorderSide(
                        color: colors.onSurfaceVariant.withValues(alpha: 0.16),
                      ),
                    ),
                  ),
                  child: Text(
                    genre,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// A wide window gets the anime page's layout: the artwork across the top
  /// with the title, the buttons and the synopsis on it, then the chapters
  /// on the same page, then the particulars.
  Widget _wideScaffold(
    BuildContext context, {
    required MultimediaItem item,
    required MangaDetailsState state,
    required List<DownloadItem> downloads,
    required dynamic libraryNotifier,
    required bool isFavorite,
    required LibraryCategory? currentCategory,
  }) {
    final controller = ref.read(
      mangaDetailsControllerProvider(widget.item.url).notifier,
    );
    final chapters = state.chapters.asData?.value;
    void open(MangaChapter chapter) {
      final onOpen = widget.onOpenChapter;
      if (onOpen != null) {
        onOpen(chapter);
      } else {
        unawaited(_openChapter(item, chapter, chapters ?? <MangaChapter>[]));
      }
    }

    final l10n = AppLocalizations.of(context);
    final chapterTitle = chapters == null || chapters.isEmpty
        ? l10n?.chapters ??
              appText(context, english: 'Chapters', arabic: 'الفصول')
        : '${l10n?.chapters ?? appText(context, english: 'Chapters', arabic: 'الفصول')} (${chapters.length})';

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _wideAppBar(context),
      body: DetailsDesktopHero(
        displayItem: item,
        details: state.details.asData?.value,
        detailsState: state.details,
        isMovie: false,
        manga: true,
        showPoster: true,
        // A phone gets the same page with the header drawn smaller, as the
        // phone anime page has it.
        compact: !context.isTabletOrLarger,
        itemUrl: widget.item.url,
        onRefresh: controller.retry,
        onPosterTap: () => _showPoster(item),
        heroActions: _heroActions(
          context,
          item,
          chapters: chapters,
          open: open,
          libraryNotifier: libraryNotifier,
          isFavorite: isFavorite,
          currentCategory: currentCategory,
        ),
        story: state.details.hasError ? null : _heroStory(context, item),
        child: Column(
          key: const ValueKey<String>('manga-details-wide'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              chapterTitle,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
          ],
        ),
        // The chapters are built as they scroll into view.
        slivers: <Widget>[
          state.chapters.when(
            loading: () => const SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                child: Center(child: AppLoadingIndicator()),
              ),
            ),
            error: (_, _) => SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                child: _RetryPanel(onRetry: controller.retry),
              ),
            ),
            data: (chapters) => MangaChapterList(
              embedded: true,
              chapters: chapters,
              downloads: downloads,
              onDeleteDownload: (download) =>
                  unawaited(confirmAndRemoveDownload(context, ref, download)),
              onOpen: open,
              onDownload:
                  widget.onDownloadChapter ??
                  (chapter) => unawaited(controller.downloadChapter(chapter)),
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 44),
                if (state.details.hasError)
                  SizedBox(
                    height: 200,
                    child: _RetryPanel(onRetry: controller.retry),
                  )
                else
                  MangaInformationSection(item: item),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(mangaDetailsControllerProvider(widget.item.url));
    final baseItem = state.details.asData?.value ?? state.item ?? widget.item;
    final customCover = ref.watch(
      mangaReaderCustomCoversProvider.select(
        (covers) => covers[baseItem.url]?.trim() ?? '',
      ),
    );
    final item = mangaDetailsItemWithCustomCover(baseItem, customCover);
    final downloads =
        ref.watch(downloadsProvider).value ?? const <DownloadItem>[];

    dynamic libraryNotifier;
    var isFavorite = false;
    LibraryCategory? currentCategory;
    try {
      ref.watch(libraryProvider);
      libraryNotifier = ref.read(libraryProvider.notifier);
      isFavorite = libraryNotifier.isFavorite(item.url) as bool;
      currentCategory =
          libraryNotifier.itemCategory(item.url) as LibraryCategory?;
    } catch (_) {
      // Isolated widget tests can intentionally omit persistent storage.
    }

    final buttons = _headerButtons(
      context,
      item,
      libraryNotifier: libraryNotifier,
      isFavorite: isFavorite,
      currentCategory: currentCategory,
    );
    // Every size takes the anime page's layout: the artwork, the details
    // and the chapters on one page.
    final scaffold = _wideScaffold(
      context,
      item: item,
      state: state,
      downloads: downloads,
      libraryNotifier: libraryNotifier,
      isFavorite: isFavorite,
      currentCategory: currentCategory,
    );

    if (!appleUsesPersistentLiquidGlassHeader) return scaffold;
    return ApplePersistentGlassHeaderScope(
      onBack: () => Navigator.of(context).maybePop(),
      backForegroundColor: Theme.of(context).colorScheme.onSurface,
      backFallbackColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      trailingButtons: buttons,
      child: scaffold,
    );
  }
}

class _RetryPanel extends StatelessWidget {
  const _RetryPanel({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    return Center(
      child: FilledButton.tonalIcon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: Text(l10n?.retry ?? (isArabic ? 'إعادة المحاولة' : 'Retry')),
      ),
    );
  }
}

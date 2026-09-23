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
import '../../../core/utils/localized_text.dart';
import '../../../core/utils/window_controls_inset.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import '../../../shared/widgets/expandable_text.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/underline_segment_tabs.dart';
import '../../details/presentation/widgets/details_rating_actions.dart';
import '../../library/presentation/library_auth.dart';
import '../../library/presentation/library_provider.dart';
import '../../settings/presentation/account_screen.dart';
import '../reader/manga_reader_cover_provider.dart';
import 'manga_details_controller.dart';
import 'widgets/manga_chapter_list.dart';
import 'widgets/manga_details_hero.dart';

@visibleForTesting
MultimediaItem mangaDetailsItemWithCustomCover(
  MultimediaItem baseItem,
  String customCover,
) {
  final cover = customCover.trim();
  return cover.isEmpty
      ? baseItem
      : baseItem.copyWith(
          posterUrl: cover,
          fullPosterUrl: cover,
        );
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

class _MangaDetailsScreenState extends ConsumerState<MangaDetailsScreen>
    with SingleTickerProviderStateMixin {
  static const String _removeLibraryAction = '__remove_from_library__';

  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(mangaDetailsControllerProvider(widget.item.url).notifier)
          .load(widget.item);
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String _categoryLabel(BuildContext context, LibraryCategory category) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    return switch (category) {
      LibraryCategory.favorite => ar ? 'المفضلة' : 'Favorites',
      LibraryCategory.watching => ar ? 'أقرأها حاليًا' : 'Reading',
      LibraryCategory.continueLater =>
        ar ? 'أكملها لاحقًا' : 'Continue later',
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
            : (value) => _setLibraryCategory(
                  libraryNotifier,
                  item,
                  value,
                ),
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

  PreferredSizeWidget _appBar(
    BuildContext context,
    List<AppleLiquidGlassToolbarButton> buttons,
  ) {
    final colors = Theme.of(context).colorScheme;
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: AppBar(
          backgroundColor: Colors.black,
          automaticallyImplyLeading: false,
          elevation: 0,
          scrolledUnderElevation: 0,
          leadingWidth: appleUsesPersistentLiquidGlassHeader ? 0 : 64,
          leading: appleUsesPersistentLiquidGlassHeader
              ? null
              : Padding(
                  padding: EdgeInsets.only(
                    left: 8 + windowControlsLeadingInset,
                  ),
                  child: AppleLiquidGlassBackButton(
                    size: 46,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
          actions: appleUsesPersistentLiquidGlassHeader
              ? const <Widget>[]
              : <Widget>[
                  Padding(
                    padding: EdgeInsets.only(
                      right: 8 + windowControlsTrailingInset,
                    ),
                    child: AppleLiquidGlassActionGroup(
                      height: 46,
                      fallbackColor: colors.surfaceContainerHigh,
                      children: buttons,
                    ),
                  ),
                ],
        ),
      ),
    );
  }

  Widget _buildTabs(BuildContext context, int chapterCount) {
    final l10n = AppLocalizations.of(context);
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final chapterLabel = chapterCount > 0
        ? '${l10n?.chapters ?? (ar ? 'الفصول' : 'Chapters')} ($chapterCount)'
        : l10n?.chapters ?? (ar ? 'الفصول' : 'Chapters');
    return Directionality(
      textDirection: ar ? TextDirection.rtl : TextDirection.ltr,
      child: FilterStyleTabBar(
        controller: _tabs,
        isScrollable: false,
        tabs: <Widget>[
          FilterStyleTab(
            icon: Icons.info_outline_rounded,
            label: l10n?.mangaDetails ?? (ar ? 'التفاصيل' : 'Details'),
          ),
          FilterStyleTab(
            icon: Icons.menu_book_outlined,
            label: chapterLabel,
          ),
        ],
      ),
    );
  }

  Future<void> _copyMangaTitle(BuildContext context, String title) async {
    await Clipboard.setData(ClipboardData(text: title));
    await HapticFeedback.selectionClick();

    if (!context.mounted) return;

    ref
        .read(notificationServiceProvider)
        .showSuccess(
          appText(context, english: 'Title copied', arabic: 'تم نسخ العنوان'),
        );
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(
      mangaDetailsControllerProvider(widget.item.url),
    );
    final baseItem = state.details.asData?.value ?? state.item ?? widget.item;
    final customCover = ref.watch(
      mangaReaderCustomCoversProvider.select(
        (covers) => covers[baseItem.url]?.trim() ?? '',
      ),
    );
    final item = mangaDetailsItemWithCustomCover(baseItem, customCover);
    final chapterCount = state.chapters.asData?.value.length ?? 0;

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
    final scaffold = Scaffold(
      backgroundColor: Colors.black,
      appBar: _appBar(context, buttons),
      body: Column(
        children: <Widget>[
          _buildTabs(context, chapterCount),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                _MangaDetailsTab(
                  item: item,
                  loading: state.details.isLoading,
                  error: state.details.hasError,
                  onRetry: () => ref
                      .read(
                        mangaDetailsControllerProvider(widget.item.url).notifier,
                      )
                      .retry(),
                  onPosterTap: () => _showPoster(item),
                  onTitleLongPress: () => _copyMangaTitle(context, item.title),
                  onRate: () => _rateManga(item),
                ),
                state.chapters.when(
                  loading: () =>
                      const Center(child: AppLoadingIndicator()),
                  error: (_, __) => _RetryPanel(
                    onRetry: () => ref
                        .read(
                          mangaDetailsControllerProvider(
                            widget.item.url,
                          ).notifier,
                        )
                        .retry(),
                  ),
                  data: (chapters) => MangaChapterList(
                    chapters: chapters,
                    onOpen: widget.onOpenChapter ??
                        (chapter) => MangaReaderRoute(
                          $extra: MangaReaderRouteExtra(
                            manga: item,
                            chapter: chapter,
                            chapters: chapters,
                          ),
                        ).push<void>(context),
                    onDownload: widget.onDownloadChapter ??
                        (chapter) => unawaited(
                          ref
                              .read(
                                mangaDetailsControllerProvider(
                                  widget.item.url,
                                ).notifier,
                              )
                              .downloadChapter(chapter),
                        ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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

class _MangaDetailsTab extends StatelessWidget {
  const _MangaDetailsTab({
    required this.item,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.onPosterTap,
    required this.onTitleLongPress,
    required this.onRate,
  });

  final MultimediaItem item;
  final bool loading;
  final bool error;
  final Future<void> Function() onRetry;
  final VoidCallback onPosterTap;
  final VoidCallback onTitleLongPress;
  final VoidCallback onRate;

  List<String> _genres() {
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

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final l10n = AppLocalizations.of(context);
    final genres = _genres();

    return CustomScrollView(
      key: const PageStorageKey<String>('manga-details-info-tab'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: MangaDetailsHero(
            key: const ValueKey('manga-details-hero'),
            item: item,
            isLoading: loading,
            onPosterTap: onPosterTap,
            onTitleLongPress: onTitleLongPress,
          ),
        ),
        if (error)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _RetryPanel(onRetry: onRetry),
          )
        else
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _MangaRateAction(onPressed: onRate),
                      const SizedBox(height: 16),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Theme.of(context)
                                .colorScheme
                                .outlineVariant
                                .withValues(alpha: 0.38),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              ExpandableText(
                                text: (item.description ?? '').trim().isEmpty
                                    ? (l10n?.noDescription ??
                                          (ar
                                              ? 'لا يوجد وصف'
                                              : 'No description'))
                                    : item.description!.trim(),
                                maxLines: 5,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyLarge
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      height: 1.55,
                                    ),
                              ),
                              if (genres.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 14),
                                Wrap(
                                  spacing: 7,
                                  runSpacing: 7,
                                  children: <Widget>[
                                    for (final genre in genres)
                                      Container(
                                        key: ValueKey<String>(
                                          'manga-genre-$genre',
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          borderRadius:
                                              BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          genre,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium
                                              ?.copyWith(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onPrimary,
                                                fontWeight: FontWeight.w600,
                                                height: 1,
                                              ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),

                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MangaRateAction extends StatelessWidget {
  const _MangaRateAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ar = Localizations.localeOf(context).languageCode == 'ar';
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.38),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: SizedBox(
          height: 62,
          child: Material(
            color: colors.surfaceContainerHigh.withValues(alpha: 0.70),
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('manga-rate-action'),
              onTap: onPressed,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.star_border_rounded),
                  const SizedBox(width: 10),
                  Text(
                    ar ? 'قيّم' : 'Rate',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
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

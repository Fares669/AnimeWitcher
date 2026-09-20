import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/account/account_providers.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/catalog_ltr.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../../../settings/presentation/account_screen.dart';
import '../library_auth.dart';
import '../library_provider.dart';
import '../library_media_kind.dart';

import '../library_state.dart';
import '../../../../shared/widgets/loading_indicator.dart';

class BookmarksTab extends ConsumerStatefulWidget {
  const BookmarksTab({super.key});

  @override
  ConsumerState<BookmarksTab> createState() => _BookmarksTabState();
}

class _BookmarksTabState extends ConsumerState<BookmarksTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final libraryState = ref.watch(libraryProvider);
    final isDesktop = context.isDesktop;
    final gridHorizontalPadding =
        MultimediaCardLayout.catalogGridHorizontalPadding(context);
    final gridCrossAxisSpacing =
        MultimediaCardLayout.catalogGridCrossAxisSpacing(context);
    final gridMainAxisSpacing =
        MultimediaCardLayout.catalogGridMainAxisSpacing(context);
    // Poster *width* budget per column. The previous value was named
    // "totalHeight" and fed into maxCrossAxisExtent, so the library grid
    // sized its columns from a height and ended up denser than every other
    // catalog page. Use the same width budget the other grids use.
    final double maxCardWidth = isDesktop ? 240.0 : 150.0;

    return switch (libraryState) {
      LibraryLoading() => const Center(child: AppLoadingIndicator()),
      LibraryError(message: final msg) => Center(child: Text(msg)),
      LibraryEmpty() => _buildEmpty(context, libraryState.mediaKind),
      LibrarySuccess(items: final items) => CatalogLtr(
        child: GridView.builder(
          padding: EdgeInsets.fromLTRB(
            gridHorizontalPadding,
            LayoutConstants.spacingMd,
            gridHorizontalPadding,
            100,
          ),
          gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
            context,
            maxCrossAxisExtent: maxCardWidth,
            childAspectRatio: MultimediaCardLayout.gridAspectRatio(
              isPortrait: true,
              isDesktop: isDesktop,
            ),
            crossAxisSpacing: gridCrossAxisSpacing,
            mainAxisSpacing: gridMainAxisSpacing,
            handsetPortraitCrossAxisCount:
                MultimediaCardLayout.handsetPortraitGridColumns,
            horizontalPadding: gridHorizontalPadding,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return MultimediaCard.fromItem(
              key: ValueKey(item.url),
              item: item,
              heroTag: 'lib_bookmark_${item.url}_$index',
              onTap: () {
                if (item.contentType == MultimediaContentType.manga) {
                  MangaDetailsRoute(
                    $extra: MangaDetailsRouteExtra(item: item),
                  ).push<void>(context);
                  return;
                }
                DetailsRoute(
                  $extra: DetailsRouteExtra(item: item),
                ).push<void>(context);
              },
            );
          },
        ),
      ),
    };
  }

  Widget _buildEmpty(
    BuildContext context,
    LibraryMediaKind mediaKind,
  ) {
    final isManga = mediaKind == LibraryMediaKind.manga;
    final signedIn =
        isManga ||
        (ref
                .watch(animeWitcherAccountControllerProvider)
                .asData
                ?.value
                .isSignedIn ??
            false);
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              signedIn
                  ? Icons.bookmark_outline_rounded
                  : Icons.lock_outline_rounded,
              size: 64,
              color: Theme.of(context).dividerColor,
            ),
            const SizedBox(height: 16),
            Text(
              signedIn
                  ? appText(
                      context,
                      english: isManga
                          ? 'No manga in this list yet'
                          : 'No titles in this list yet',
                      arabic: isManga
                          ? 'لا توجد مانجا في هذه القائمة بعد'
                          : 'لا توجد أعمال في هذه القائمة بعد',
                    )
                  : librarySignInRequiredMessage(isArabic: true),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (!signedIn) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AnimeWitcherAccountScreen(),
                      ),
                    ),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: colors.onPrimary,
                ),
                child: Text(
                  appText(context, english: 'Sign in', arabic: 'تسجيل الدخول'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/account/account_providers.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/catalog_ltr.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../../../settings/presentation/account_screen.dart';
import '../library_auth.dart';
import '../library_provider.dart';

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
    final isLarge = context.isTabletOrLarger;
    final double totalHeight = isLarge ? 180.0 : 150.0;

    return switch (libraryState) {
      LibraryLoading() => const Center(child: AppLoadingIndicator()),
      LibraryError(message: final msg) => Center(child: Text(msg)),
      LibraryEmpty() => _buildEmpty(context),
      LibrarySuccess(items: final items) => CatalogLtr(
        child: GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            LayoutConstants.spacingMd,
            LayoutConstants.spacingMd,
            LayoutConstants.spacingMd,
            100,
          ),
          gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
            context,
            maxCrossAxisExtent: totalHeight,
            childAspectRatio: MultimediaCardLayout.portraitGridAspectRatio,
            crossAxisSpacing: LayoutConstants.spacingMd,
            mainAxisSpacing: LayoutConstants.spacingMd,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return MultimediaCard.fromItem(
              key: ValueKey(item.url),
              item: item,
              heroTag: 'lib_bookmark_${item.url}_$index',
              onTap: () => DetailsRoute(
                $extra: DetailsRouteExtra(item: item),
              ).push<void>(context),
            );
          },
        ),
      ),
    };
  }

  Widget _buildEmpty(BuildContext context) {
    final signedIn =
        ref
            .watch(animeWitcherAccountControllerProvider)
            .asData
            ?.value
            .isSignedIn ??
        false;
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
                      english: 'No titles in this list yet',
                      arabic: 'لا توجد أعمال في هذه القائمة بعد',
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

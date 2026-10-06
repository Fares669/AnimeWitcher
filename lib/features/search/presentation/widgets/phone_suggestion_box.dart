import 'package:flutter/material.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../../shared/widgets/fallback_poster_image.dart';
import '../../../../shared/widgets/poster_plate.dart';

/// On a phone, the box under the search field while it is typed in: the
/// first few results as compact rows, and a last row that runs the full
/// search, as Enter does. The search page stays in view below it.
class PhoneSuggestionBox extends StatelessWidget {
  const PhoneSuggestionBox({
    super.key,
    required this.query,
    required this.items,
    required this.loading,
    required this.onOpen,
    required this.onSeeAll,
  });

  final String query;
  final List<MultimediaItem> items;
  final bool loading;
  final ValueChanged<MultimediaItem> onOpen;
  final VoidCallback onSeeAll;

  static const int _shown = 6;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shown = items.take(_shown).toList(growable: false);
    return Material(
      key: const ValueKey<String>('phone-suggestion-box'),
      color: colors.surfaceContainerHigh,
      elevation: 12,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 2,
            child: loading ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 22),
              child: Text(
                loading
                    ? appText(
                        context,
                        english: 'Searching…',
                        arabic: 'جارٍ البحث…',
                      )
                    : appText(
                        context,
                        english: 'No results found',
                        arabic: 'لم يتم العثور على نتائج',
                      ),
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            )
          else
            for (final item in shown) _row(context, item),
          Divider(
            height: 1,
            color: colors.outlineVariant.withValues(alpha: 0.4),
          ),
          InkWell(
            key: const ValueKey<String>('phone-suggestion-see-all'),
            onTap: onSeeAll,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      appText(
                        context,
                        english: 'All results for "$query"',
                        arabic: 'عرض كل النتائج لـ "$query"',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const Icon(Icons.chevron_left_rounded),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, MultimediaItem item) {
    final colors = Theme.of(context).colorScheme;
    final kind = switch (item.contentType) {
      MultimediaContentType.movie => appText(
        context,
        english: 'Movie',
        arabic: 'فيلم',
      ),
      MultimediaContentType.manga => appText(
        context,
        english: 'Manga',
        arabic: 'مانجا',
      ),
      _ => appText(context, english: 'Series', arabic: 'مسلسل'),
    };
    final year = item.year;
    return InkWell(
      key: ValueKey<String>('phone-suggestion-${item.url}'),
      onTap: () => onOpen(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 36,
                height: 52,
                child: FallbackPosterImage(
                  imageUrl: item.posterUrl,
                  malId: item.artworkLookupMalId,
                  title: item.artworkLookupTitle,
                  memCacheWidth: 108,
                  placeholder: (_) => PosterPlate(seed: item.title),
                  errorWidget: (_) => PosterPlate(seed: item.title),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    year != null && year > 0 ? '$kind  •  $year' : kind,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

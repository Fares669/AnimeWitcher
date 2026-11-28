import 'package:flutter/material.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../shared/widgets/embedded_poster_grid.dart';
import '../../../shared/widgets/multimedia_card.dart';

/// Character-details anime list: 3 posters per row, first card on the right.
class CharacterAnimesGrid extends StatelessWidget {
  const CharacterAnimesGrid({
    super.key,
    required this.title,
    required this.items,
    required this.onItemTap,
  });

  final String title;
  final List<MultimediaItem> items;
  final void Function(MultimediaItem) onItemTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            title,
            textAlign: TextAlign.start,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        buildEmbeddedPosterGrid(
          context,
          key: const ValueKey('character-animes-grid'),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return MultimediaCard.fromItem(
              key: ValueKey('character-animes-grid-$index'),
              item: item,
              heroTag: heroTagWithUrl('character_anime', item, index),
              showRelationBadge: true,
              onTap: () => onItemTap(item),
            );
          },
        ),
      ],
    );
  }
}

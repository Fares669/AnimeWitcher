import 'package:flutter/material.dart';

import '../../../core/account/animewitcher_character_models.dart';
import '../../../shared/widgets/cards_wrapper.dart';
import '../../../shared/widgets/multimedia_card.dart';
import 'character_portrait_image.dart';

class CharacterPosterCard extends StatelessWidget {
  const CharacterPosterCard({
    super.key,
    required this.character,
    required this.onTap,
    this.heroTag,
  });

  final AnimeWitcherCharacterHit character;
  final VoidCallback onTap;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final imageUrl = character.imageUrl ?? '';
    final tag = heroTag ?? 'character-${character.id}';

    return CardsWrapper(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MultimediaCardLayout.posterRadius),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Hero(
              tag: tag,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(
                  MultimediaCardLayout.posterRadius,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CharacterPortraitImage(
                      url: imageUrl,
                      name: character.name,
                      radius: MultimediaCardLayout.posterRadius,
                      standardWidth: 160,
                      filterQuality: FilterQuality.medium,
                    ),
                    if (character.likes > 0)
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.favorite_rounded,
                                size: 11,
                                color: colors.onPrimary,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '${character.likes}',
                                style: TextStyle(
                                  color: colors.onPrimary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  height: 1.1,
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
          ),
          const SizedBox(height: characterPortraitCaptionGap),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              character.name,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              textDirection: TextDirection.ltr,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

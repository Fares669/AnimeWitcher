import 'package:flutter/material.dart';

import '../../../../core/account/animewitcher_character_models.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../characters/presentation/character_card.dart';
import 'details_poster_grid.dart';

class DetailsCharacterRails extends StatelessWidget {
  const DetailsCharacterRails({
    super.key,
    required this.cast,
    required this.onCharacterTap,
    this.onShowMore,
  });

  final List<Actor> cast;
  final void Function(Actor actor) onCharacterTap;
  final void Function(String role)? onShowMore;

  static List<Actor> mainCast(List<Actor> cast) {
    return cast
        .where((actor) => actor.role == 'شخصية رئيسية')
        .toList(growable: false);
  }

  static List<Actor> supportingCast(List<Actor> cast) {
    return cast
        .where((actor) => actor.role != 'شخصية رئيسية')
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final main = mainCast(cast);
    final supporting = supportingCast(cast);
    if (main.isEmpty && supporting.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (main.isNotEmpty)
          _CharacterRoleRail(
            title: animeWitcherMainCharactersHeader,
            characters: main,
            role: 'Main',
            onCharacterTap: onCharacterTap,
            onShowMore: onShowMore,
          ),
        if (main.isNotEmpty && supporting.isNotEmpty)
          const SizedBox(height: 18),
        if (supporting.isNotEmpty)
          _CharacterRoleRail(
            title: animeWitcherSupportingCharactersHeader,
            characters: supporting,
            role: 'Supporting',
            onCharacterTap: onCharacterTap,
            onShowMore: onShowMore,
          ),
      ],
    );
  }
}

class _CharacterRoleRail extends StatelessWidget {
  const _CharacterRoleRail({
    required this.title,
    required this.characters,
    required this.role,
    required this.onCharacterTap,
    this.onShowMore,
  });

  final String title;
  final List<Actor> characters;
  final String role;
  final void Function(Actor actor) onCharacterTap;
  final void Function(String role)? onShowMore;

  @override
  Widget build(BuildContext context) {
    final showMore =
        characters.length >= animeWitcherAnimeCastStripLimit &&
        onShowMore != null;
    const cardWidth = 110.0;
    const rowHeight = 198.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        SizedBox(
          height: rowHeight,
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: ListView.separated(
              key: ValueKey('details-character-rail-$role'),
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: characters.length + (showMore ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                if (showMore && index >= characters.length) {
                  return SizedBox(
                    width: cardWidth,
                    height: rowHeight,
                    child: DetailsShowMoreTile(
                      compact: true,
                      onTap: () => onShowMore!(role),
                    ),
                  );
                }
                return SizedBox(
                  width: cardWidth,
                  height: rowHeight,
                  child: CharacterPosterCard(
                    key: ValueKey('details-character-$role-$index'),
                    character: AnimeWitcherCharacterHit(
                      id: characters[index].id?.trim() ?? '',
                      name: characters[index].name,
                      imageUrl: characters[index].image,
                      likes: characters[index].likes,
                    ),
                    onTap: (characters[index].id?.trim() ?? '').isEmpty
                        ? () {}
                        : () => onCharacterTap(characters[index]),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

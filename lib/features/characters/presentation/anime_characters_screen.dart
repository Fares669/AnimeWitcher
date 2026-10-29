import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/animewitcher_character_models.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/native_provider_resolution.dart';
import '../../../shared/widgets/catalog_page.dart';
import 'character_card.dart';
import 'character_details_screen.dart';

class AnimeCharactersScreen extends ConsumerStatefulWidget {
  const AnimeCharactersScreen({
    super.key,
    required this.animeId,
    this.animeTitle,
    this.characterType,
  });

  final String animeId;
  final String? animeTitle;

  /// APK `CharactersByIds` role filter: `Main` or `Supporting`.
  final String? characterType;

  @override
  ConsumerState<AnimeCharactersScreen> createState() =>
      _AnimeCharactersScreenState();
}

class _AnimeCharactersScreenState extends ConsumerState<AnimeCharactersScreen> {
  final List<Actor> _cast = <Actor>[];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_load());
    });
  }

  Future<void> _load() async {
    final provider = ref.nativeProvider;
    if (provider == null) {
      if (mounted) {
        setState(() {
          _error = nativeProviderUnavailable();
          _loading = false;
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final role = widget.characterType?.trim();
      final cast = role == null || role.isEmpty
          ? await provider.getAnimeCharacters(widget.animeId)
          : await provider.getAnimeCharactersByRole(widget.animeId, role);
      if (!mounted) return;
      setState(() {
        _cast
          ..clear()
          ..addAll(cast);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = widget.characterType?.trim();
    final title = role == 'Main'
        ? animeWitcherMainCharactersHeader
        : role == 'Supporting'
        ? animeWitcherSupportingCharactersHeader
        : (widget.animeTitle?.trim().isNotEmpty == true
              ? widget.animeTitle!
              : 'الشخصيات');
    return CatalogPage(
      title: title,
      onBack: () => Navigator.of(context).pop(),
      builder: (context, topInset) => CatalogBody(
        topInset: topInset,
        isLoading: _loading,
        errorMessage: _error != null ? 'تعذر تحميل الشخصيات' : null,
        onRetry: _load,
        emptyMessage: animeWitcherCharactersEmptyMessage,
        onRefresh: _load,
        characterTiles: true,
        maxCrossAxisExtent: 140,
        crossAxisSpacingFallback: 12,
        mainAxisSpacingFallback: 14,
        itemCount: _cast.length,
        itemBuilder: (context, index) {
          final actor = _cast[index];
          final id = actor.id?.trim() ?? '';
          return CharacterPosterCard(
            character: AnimeWitcherCharacterHit(
              id: id,
              name: actor.name,
              imageUrl: actor.image,
              likes: actor.likes,
            ),
            onTap: id.isEmpty
                ? () {}
                : () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => CharacterDetailsScreen(
                          characterId: id,
                          initialName: actor.name,
                          initialImageUrl: actor.image,
                        ),
                      ),
                    );
                  },
          );
        },
      ),
    );
  }
}

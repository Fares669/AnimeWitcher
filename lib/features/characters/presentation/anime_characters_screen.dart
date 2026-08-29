import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/animewitcher_character_models.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import '../../../shared/widgets/catalog_ltr.dart';
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

class _AnimeCharactersScreenState
    extends ConsumerState<AnimeCharactersScreen> {
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

  bool _isArabic(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  AnimeWitcherNativeProvider? _resolveProvider() {
    final active = ref.read(activeProviderProvider);
    if (active is AnimeWitcherNativeProvider) return active;
    for (final provider in ref.read(extensionManagerProvider)) {
      if (provider is AnimeWitcherNativeProvider) return provider;
    }
    return null;
  }

  Future<void> _load() async {
    final provider = _resolveProvider();
    if (provider == null) {
      if (mounted) {
        setState(() {
          _error = StateError('AnimeWitcher Native unavailable');
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
    final isArabic = _isArabic(context);
    final role = widget.characterType?.trim();
    final title = role == 'Main'
        ? animeWitcherMainCharactersHeader
        : role == 'Supporting'
            ? animeWitcherSupportingCharactersHeader
            : (widget.animeTitle?.trim().isNotEmpty == true
                ? widget.animeTitle!
                : (isArabic ? 'الشخصيات' : 'Characters'));
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppBar(
            automaticallyImplyLeading: false,
            centerTitle: false,
            titleSpacing: 16,
            title: ApplePersistentGlassHeaderScope(
              enabled: Navigator.of(context).canPop(),
              onBack: () => Navigator.of(context).pop(),
              child: Align(
                alignment: isArabic
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Directionality(
                  textDirection: isArabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: Text(title),
                ),
              ),
            ),
            leading: appleUsesPersistentLiquidGlassHeader
                ? null
                : AppleLiquidGlassBackButton(
                    onPressed: () => Navigator.of(context).pop(),
                  ),
            elevation: 0,
          ),
        ),
      ),
      body: _loading
          ? const AnimeCatalogShimmer()
          : _error != null
              ? Center(
                  child: FilledButton.tonalIcon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(isArabic ? 'إعادة المحاولة' : 'Retry'),
                  ),
                )
              : _cast.isEmpty
                  ? Center(
                      child: Text(
                        isArabic
                            ? animeWitcherCharactersEmptyMessage
                            : 'No characters have been added yet',
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: CatalogLtr(
                        child: GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
                          gridDelegate:
                              ResponsiveBreakpoints.animeGridDelegate(
                            context,
                            maxCrossAxisExtent: 140,
                            childAspectRatio: 0.58,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 14,
                            handsetPortraitCrossAxisCount: 3,
                          ),
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
                                          builder: (_) =>
                                              CharacterDetailsScreen(
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
                      ),
                    ),
    );
  }
}

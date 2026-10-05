import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/animewitcher_account_models.dart';
import '../../../core/account/animewitcher_character_models.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/utils/artwork_quality.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../core/utils/window_controls_inset.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import '../../../shared/widgets/app_page_header.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/shimmer_placeholder.dart';
import '../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../comments/presentation/animewitcher_comments_screen.dart';
import '../../details/presentation/details_screen.dart';
import '../../settings/presentation/account_screen.dart';
import 'character_animes_grid.dart';

class CharacterDetailsScreen extends ConsumerStatefulWidget {
  const CharacterDetailsScreen({
    super.key,
    required this.characterId,
    this.initialName,
    this.initialImageUrl,
  });

  final String characterId;
  final String? initialName;
  final String? initialImageUrl;

  @override
  ConsumerState<CharacterDetailsScreen> createState() =>
      _CharacterDetailsScreenState();
}

class _CharacterDetailsScreenState
    extends ConsumerState<CharacterDetailsScreen> {
  AnimeWitcherCharacterDocument? _document;
  List<AnimeWitcherCharacterShow> _animes = const <AnimeWitcherCharacterShow>[];
  Object? _error;
  Object? _animesError;
  bool _loading = true;
  bool _favorite = false;
  bool _favoriteBusy = false;
  bool _animesLoading = false;

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
      final service = ref.read(animeWitcherAccountServiceProvider);
      final results = await Future.wait<Object?>([
        provider.getCharacterDocument(widget.characterId),
        if (service.isSignedIn)
          service.isFavoriteCharacter(widget.characterId)
        else
          Future<bool>.value(false),
      ]);
      if (!mounted) return;
      final document = results[0] as AnimeWitcherCharacterDocument?;
      final favorite = results[1] as bool;
      if (document == null) {
        setState(() {
          _error = StateError('missing');
          _loading = false;
        });
        return;
      }
      setState(() {
        _document = document;
        _favorite = favorite;
        _loading = false;
        _animes = const <AnimeWitcherCharacterShow>[];
        _animesError = null;
        _animesLoading = true;
      });
      unawaited(_loadAnimes(provider, document));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadAnimes(
    AnimeWitcherNativeProvider provider,
    AnimeWitcherCharacterDocument document,
  ) async {
    try {
      final animes = await provider.getCharacterAnimes(document);
      if (!mounted) return;
      setState(() {
        _animes = animes;
        _animesError = null;
        _animesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _animesError = error;
        _animesLoading = false;
      });
    }
  }

  void _showSignInRequired(bool isArabic) {
    ref.read(notificationServiceProvider).showInfo(
      isArabic ? 'يجب تسجيل الدخول' : 'Sign in first',
      icon: Icons.lock_outline_rounded,
      duration: const Duration(seconds: 3),
    );
  }

  Future<void> _toggleFavorite() async {
    if (_favoriteBusy) return;
    final isArabic = _isArabic(context);
    final service = ref.read(animeWitcherAccountServiceProvider);
    if (!service.isSignedIn) {
      _showSignInRequired(isArabic);
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => const AnimeWitcherAccountScreen(),
        ),
      );
      if (!mounted) return;
      if (service.isSignedIn) await _toggleFavorite();
      return;
    }
    final previous = _favorite;
    setState(() {
      _favoriteBusy = true;
      _favorite = !previous;
    });
    try {
      final next = await service.toggleFavoriteCharacter(widget.characterId);
      if (!mounted) return;
      setState(() {
        _favorite = next;
        _favoriteBusy = false;
      });
    } on AnimeWitcherAccountException catch (error) {
      if (!mounted) return;
      setState(() {
        _favorite = previous;
        _favoriteBusy = false;
      });
      if (error.code == 'not-signed-in') {
        _showSignInRequired(isArabic);
      } else {
        ref.read(notificationServiceProvider).showError(
          isArabic ? 'تعذر تحديث المفضلة' : 'Could not update favorites',
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _favorite = previous;
        _favoriteBusy = false;
      });
      ref.read(notificationServiceProvider).showError(
        isArabic ? 'تعذر تحديث المفضلة' : 'Could not update favorites',
      );
    }
  }

  Future<void> _openComments() async {
    final document = _document;
    if (document == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AnimeWitcherCommentsScreen(
          target: animeWitcherCharacterCommentTarget(
            characterId: document.id,
            name: document.name,
          ),
        ),
      ),
    );
  }

  Future<void> _openMal() async {
    final url = _document?.url?.trim() ?? '';
    if (url.isEmpty) {
      ref.read(notificationServiceProvider).showInfo(
        _isArabic(context) ? 'لا يوجد رابط' : 'No link available',
      );
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  List<AppleLiquidGlassToolbarButton> _buildHeaderButtons(
    BuildContext context,
  ) {
    const favoriteRed = Color(0xFFFF3B30);
    final colors = Theme.of(context).colorScheme;
    final isArabic = _isArabic(context);
    final hasDocument = _document != null;

    return <AppleLiquidGlassToolbarButton>[
      AppleLiquidGlassToolbarButton(
        tooltip: isArabic ? 'التعليقات' : 'Comments',
        icon: Icons.chat_bubble_outline_rounded,
        color: colors.onSurface,
        onPressed: hasDocument ? _openComments : null,
      ),
      AppleLiquidGlassToolbarButton(
        tooltip: _favorite
            ? (isArabic ? 'إزالة من المفضلة' : 'Remove favorite')
            : (isArabic ? 'إضافة إلى المفضلة' : 'Add to favorites'),
        icon: _favorite
            ? Icons.favorite_rounded
            : Icons.favorite_border_rounded,
        color: _favorite ? favoriteRed : colors.onSurface,
        onPressed: _favoriteBusy ? null : _toggleFavorite,
      ),
      AppleLiquidGlassToolbarButton(
        tooltip: isArabic ? 'المزيد' : 'More',
        icon: Icons.more_horiz_rounded,
        color: colors.onSurface,
        onPressed: hasDocument ? _openMal : null,
      ),
    ];
  }

  void _openAnime(MultimediaItem item) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailsScreen(item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(accountDataRevisionProvider, (previous, next) {
      if (previous == next) return;
      unawaited(() async {
        final service = ref.read(animeWitcherAccountServiceProvider);
        if (!service.isSignedIn) {
          if (mounted) setState(() => _favorite = false);
          return;
        }
        final favorite = await service.isFavoriteCharacter(widget.characterId);
        if (mounted) setState(() => _favorite = favorite);
      }());
    });
    final isArabic = _isArabic(context);
    final document = _document;
    final name = document?.name.isNotEmpty == true
        ? document!.name
        : (widget.initialName ?? '');
    final imageUrl = document?.imageUrl ?? widget.initialImageUrl;
    final likes = document?.likes ?? 0;
    final colors = Theme.of(context).colorScheme;
    final headerButtons = _buildHeaderButtons(context);
    final isLarge = context.isTabletOrLarger;

    final headerTop = appPageHeaderContentTopInset(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: name.isEmpty ? (isArabic ? 'الشخصية' : 'Character') : name,
        onBack: () => Navigator.of(context).maybePop(),
        actions: appleUsesPersistentLiquidGlassHeader || isLarge
            ? const <Widget>[]
            : <Widget>[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: AppleLiquidGlassActionGroup(
                    height: 46,
                    fallbackColor: colors.surfaceContainerHigh,
                    children: headerButtons,
                  ),
                ),
              ],
      ),
      body: _loading && document == null
          ? Padding(
              padding: EdgeInsets.only(top: headerTop),
              child: const Center(child: AppLoadingIndicator()),
            )
          : _error != null && document == null
              ? Padding(
                  padding: EdgeInsets.only(top: headerTop),
                  child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          isArabic ? 'لا يوجد بيانات' : 'No data',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(isArabic ? 'إعادة المحاولة' : 'Retry'),
                        ),
                      ],
                      ),
                    ),
                  ),
                )
              : MouseDragRefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      headerTop + 16,
                      20,
                      110,
                    ),
                    children: [
                      Center(
                        child: SizedBox(
                          width: 168,
                          height: 236,
                          child: Hero(
                            tag: 'character-${widget.characterId}',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: ArtworkDecode(
                                paintedWidth: 240,
                                builder: (context, decodeWidth) {
                                  final url = imageUrl ?? '';
                                  if (url.isEmpty) {
                                    return ThumbnailErrorPlaceholder(
                                      label: name,
                                    );
                                  }
                                  return CachedNetworkImage(
                                    imageUrl: url,
                                    fit: BoxFit.cover,
                                    memCacheWidth: decodeWidth,
                                    placeholder: (_, _) =>
                                        ShimmerPlaceholder(
                                      borderRadius: 18,
                                    ),
                                    errorWidget: (_, _, _) =>
                                        ThumbnailErrorPlaceholder(label: name),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        name,
                        textAlign: TextAlign.center,
                        textDirection: TextDirection.ltr,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isArabic
                            ? '$likes أعجب بهذه الشخصية'
                            : '$likes liked this character',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                      if (!appleUsesPersistentLiquidGlassHeader && isLarge) ...[
                        const SizedBox(height: 20),
                        Center(
                          child: AppleLiquidGlassActionGroup(
                            height: 46,
                            fallbackColor: colors.surfaceContainerHigh,
                            children: headerButtons,
                          ),
                        ),
                      ],
                      const SizedBox(height: 28),
                      if (_animesLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: AppLoadingIndicator()),
                        )
                      else if (_animesError != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isArabic ? 'الأنميات' : 'Anime',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              isArabic
                                  ? 'تعذر تحميل الأنميات'
                                  : 'Could not load anime',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.tonalIcon(
                              onPressed: () {
                                final current = _document;
                                final provider = _resolveProvider();
                                if (current == null || provider == null) {
                                  unawaited(_load());
                                  return;
                                }
                                setState(() {
                                  _animesError = null;
                                  _animesLoading = true;
                                });
                                unawaited(_loadAnimes(provider, current));
                              },
                              icon: const Icon(Icons.refresh_rounded),
                              label: Text(
                                isArabic ? 'إعادة المحاولة' : 'Retry',
                              ),
                            ),
                          ],
                        )
                      else if (_animes.isEmpty)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isArabic ? 'الأنميات' : 'Anime',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              isArabic ? 'لا يوجد بيانات' : 'No data',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
                        )
                      else
                        CharacterAnimesGrid(
                          title: isArabic ? 'الأنميات' : 'Anime',
                          items: [
                            for (final show in _animes)
                              show.item.copyWith(
                                relationLabel: show.roleLabel,
                              ),
                          ],
                          onItemTap: _openAnime,
                        ),
                    ],
                  ),
                ),
    );
  }
}

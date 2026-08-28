import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/animewitcher_character_models.dart';
import '../../../core/account/firestore_rest_client.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/utils/request_generation.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import '../../../shared/widgets/catalog_ltr.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/underline_segment_tabs.dart';
import '../../search/presentation/search_text_direction.dart';
import '../../settings/presentation/account_screen.dart';
import 'character_card.dart';
import 'character_details_screen.dart';

class CharactersScreen extends ConsumerStatefulWidget {
  const CharactersScreen({super.key});

  @override
  ConsumerState<CharactersScreen> createState() => _CharactersScreenState();
}

class _CharactersScreenState extends ConsumerState<CharactersScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _searchDebounce = Duration(milliseconds: 350);

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _catalogController = ScrollController();
  final ScrollController _favoritesController = ScrollController();
  final RequestGeneration _catalogGeneration = RequestGeneration();
  final RequestGeneration _searchGeneration = RequestGeneration();
  final RequestGeneration _favoritesGeneration = RequestGeneration();

  late final TabController _tabController;
  Timer? _searchDebounceTimer;

  final List<AnimeWitcherCharacterHit> _catalog = <AnimeWitcherCharacterHit>[];
  final List<AnimeWitcherFavoriteCharacter> _favorites =
      <AnimeWitcherFavoriteCharacter>[];

  AnimeWitcherNativeProvider? _provider;
  Object? _catalogError;
  Object? _favoritesError;
  FirestoreDocument? _favoritesCursor;
  int _catalogPage = 0;
  bool _catalogLoading = false;
  bool _catalogHasMore = true;
  bool _searching = false;
  bool _favoritesLoading = false;
  bool _favoritesHasMore = true;
  String _activeQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _catalogController.addListener(_onCatalogScroll);
    _favoritesController.addListener(_onFavoritesScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadCatalog(reset: true));
      unawaited(_loadFavorites(reset: true));
    });
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _tabController.dispose();
    _catalogController
      ..removeListener(_onCatalogScroll)
      ..dispose();
    _favoritesController
      ..removeListener(_onFavoritesScroll)
      ..dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
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

  void _onCatalogScroll() {
    if (!_catalogController.hasClients ||
        _catalogLoading ||
        !_catalogHasMore ||
        _activeQuery.isNotEmpty) {
      return;
    }
    if (_catalogController.position.extentAfter < 520) {
      unawaited(_loadCatalog());
    }
  }

  void _onFavoritesScroll() {
    if (!_favoritesController.hasClients ||
        _favoritesLoading ||
        !_favoritesHasMore) {
      return;
    }
    if (_favoritesController.position.extentAfter < 420) {
      unawaited(_loadFavorites());
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(_searchDebounce, () {
      unawaited(_applySearch(value));
    });
  }

  Future<void> _applySearch(String raw) async {
    final query = raw.trim();
    if (query == _activeQuery && _catalog.isNotEmpty) return;
    _activeQuery = query;
    if (_tabController.index != 0) {
      _tabController.animateTo(0);
    }
    if (query.isEmpty) {
      await _loadCatalog(reset: true);
      return;
    }
    await _search(query);
  }

  Future<void> _search(String query) async {
    final provider = _provider ??= _resolveProvider();
    if (provider == null) {
      if (mounted) {
        setState(() {
          _catalogError = StateError('AnimeWitcher Native unavailable');
          _catalogLoading = false;
          _searching = false;
        });
      }
      return;
    }
    final generation = _searchGeneration.begin();
    setState(() {
      _searching = true;
      _catalogLoading = true;
      _catalogError = null;
      _catalogHasMore = false;
    });
    try {
      final page = await provider.searchCharacters(query);
      if (!mounted || !_searchGeneration.isCurrent(generation)) return;
      setState(() {
        _catalog
          ..clear()
          ..addAll(page.items);
        _catalogHasMore = false;
        _catalogLoading = false;
        _searching = false;
      });
    } catch (error) {
      if (!mounted || !_searchGeneration.isCurrent(generation)) return;
      setState(() {
        _catalogError = error;
        _catalogLoading = false;
        _searching = false;
      });
    }
  }

  Future<void> _loadCatalog({bool reset = false}) async {
    if (_catalogLoading && !reset) return;
    if (_activeQuery.isNotEmpty) {
      await _search(_activeQuery);
      return;
    }
    final provider = _provider ??= _resolveProvider();
    if (provider == null) {
      if (mounted) {
        setState(() => _catalogError = StateError('AnimeWitcher Native unavailable'));
      }
      return;
    }
    final generation = _catalogGeneration.begin();
    final page = reset ? 0 : _catalogPage;
    setState(() {
      _catalogLoading = true;
      _catalogError = null;
      if (reset) {
        _catalog.clear();
        _catalogPage = 0;
        _catalogHasMore = true;
      }
    });
    try {
      final result = await provider.getCharactersPage(page: page);
      if (!mounted || !_catalogGeneration.isCurrent(generation)) return;
      setState(() {
        final seen = _catalog.map((item) => item.id).toSet();
        for (final hit in result.items) {
          if (seen.add(hit.id)) _catalog.add(hit);
        }
        _catalogPage = result.page + 1;
        _catalogHasMore = result.hasMore;
        _catalogLoading = false;
      });
    } catch (error) {
      if (!mounted || !_catalogGeneration.isCurrent(generation)) return;
      setState(() {
        _catalogError = error;
        _catalogLoading = false;
      });
    }
  }

  Future<void> _loadFavorites({bool reset = false}) async {
    final service = ref.read(animeWitcherAccountServiceProvider);
    if (!service.isSignedIn) {
      if (mounted) {
        setState(() {
          _favorites.clear();
          _favoritesError = null;
          _favoritesLoading = false;
          _favoritesHasMore = false;
        });
      }
      return;
    }
    if (_favoritesLoading && !reset) return;
    final generation = _favoritesGeneration.begin();
    setState(() {
      _favoritesLoading = true;
      _favoritesError = null;
      if (reset) {
        _favorites.clear();
        _favoritesCursor = null;
        _favoritesHasMore = true;
      }
    });
    try {
      final page = await service.loadFavoriteCharacters(
        cursor: reset ? null : _favoritesCursor,
      );
      if (!mounted || !_favoritesGeneration.isCurrent(generation)) return;
      setState(() {
        final seen = _favorites.map((item) => item.malId).toSet();
        for (final favorite in page.items) {
          if (seen.add(favorite.malId)) _favorites.add(favorite);
        }
        _favoritesCursor = page.cursor;
        _favoritesHasMore = page.hasMore;
        _favoritesLoading = false;
      });
    } catch (error) {
      if (!mounted || !_favoritesGeneration.isCurrent(generation)) return;
      setState(() {
        _favoritesError = error;
        _favoritesLoading = false;
      });
    }
  }

  Future<void> _refreshVisible() async {
    if (_tabController.index == 1) {
      await _loadFavorites(reset: true);
      return;
    }
    if (_activeQuery.isNotEmpty) {
      await _search(_activeQuery);
      return;
    }
    await _loadCatalog(reset: true);
  }

  void _openCharacter(AnimeWitcherCharacterHit character) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CharacterDetailsScreen(
          characterId: character.id,
          initialName: character.name,
          initialImageUrl: character.imageUrl,
        ),
      ),
    );
  }

  String _catalogErrorMessage(Object error, bool isArabic) {
    if (error is AnimeWitcherSearchDisabledException) {
      return error.message.isEmpty
          ? (isArabic ? 'لا يوجد بيانات' : 'No data')
          : error.message;
    }
    return isArabic ? 'تعذر تحميل الشخصيات' : 'Could not load characters';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(accountDataRevisionProvider, (previous, next) {
      if (previous == next) return;
      unawaited(_loadFavorites(reset: true));
    });
    final isArabic = _isArabic(context);
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
                  child: Text(isArabic ? 'الشخصيات' : 'Characters'),
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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: _CharacterSearchBar(
              controller: _searchController,
              focusNode: _searchFocusNode,
              searching: _searching,
              hintText: isArabic
                  ? 'من الذي ترغب بالبحث عنه؟'
                  : 'Who do you want to search for?',
              onChanged: _onSearchChanged,
              onSubmitted: (value) {
                _searchDebounceTimer?.cancel();
                unawaited(_applySearch(value));
              },
              onClear: () {
                _searchController.clear();
                _searchDebounceTimer?.cancel();
                unawaited(_applySearch(''));
                _searchFocusNode.requestFocus();
              },
            ),
          ),
          FilterStyleTabBar(
            controller: _tabController,
            isScrollable: false,
            tabs: [
              FilterStyleTab(
                label: isArabic ? 'الشخصيات' : 'Characters',
                icon: Icons.groups_rounded,
              ),
              FilterStyleTab(
                label: isArabic ? 'المفضلة' : 'Favorites',
                icon: Icons.favorite_rounded,
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildCatalogTab(isArabic),
                _buildFavoritesTab(isArabic),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogTab(bool isArabic) {
    if (_catalog.isEmpty && _catalogLoading) {
      return const AnimeCatalogShimmer();
    }
    if (_catalog.isEmpty && _catalogError != null) {
      return _CharactersStatus(
        message: _catalogErrorMessage(_catalogError!, isArabic),
        icon: Icons.cloud_off_rounded,
        onRetry: _refreshVisible,
      );
    }
    if (_catalog.isEmpty) {
      return _CharactersStatus(
        message: _activeQuery.isEmpty
            ? (isArabic ? 'لا يوجد بيانات' : 'No data')
            : (isArabic ? 'لا توجد نتائج' : 'No results'),
        icon: _activeQuery.isEmpty
            ? Icons.person_off_rounded
            : Icons.search_off_rounded,
        onRetry: _activeQuery.isEmpty ? _refreshVisible : null,
      );
    }

    final extra = _catalogLoading && _activeQuery.isEmpty ? 1 : 0;
    return RefreshIndicator(
      onRefresh: _refreshVisible,
      child: CatalogLtr(
        child: GridView.builder(
          controller: _catalogController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
            context,
            maxCrossAxisExtent: 140,
            childAspectRatio: 0.58,
            crossAxisSpacing: 12,
            mainAxisSpacing: 14,
            handsetPortraitCrossAxisCount: 3,
          ),
          itemCount: _catalog.length + extra,
          itemBuilder: (context, index) {
            if (index >= _catalog.length) {
              return const AnimePosterShimmer();
            }
            final character = _catalog[index];
            return CharacterPosterCard(
              key: ValueKey('catalog-${character.id}'),
              character: character,
              onTap: () => _openCharacter(character),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFavoritesTab(bool isArabic) {
    final signedIn = ref.watch(animeWitcherAccountControllerProvider)
            .asData
            ?.value
            .isSignedIn ??
        ref.read(animeWitcherAccountServiceProvider).isSignedIn;
    if (!signedIn) {
      return _CharactersStatus(
        message: isArabic ? 'يجب تسجيل الدخول' : 'Sign in first',
        icon: Icons.lock_outline_rounded,
        actionLabel: isArabic ? 'تسجيل الدخول' : 'Sign in',
        onRetry: () async {
          await Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute<void>(
              builder: (_) => const AnimeWitcherAccountScreen(),
            ),
          );
          if (mounted) await _loadFavorites(reset: true);
        },
      );
    }
    if (_favorites.isEmpty && _favoritesLoading) {
      return const AnimeCatalogShimmer();
    }
    if (_favorites.isEmpty && _favoritesError != null) {
      return _CharactersStatus(
        message: isArabic
            ? 'تعذر تحميل الشخصيات المفضلة'
            : 'Could not load favorite characters',
        icon: Icons.cloud_off_rounded,
        onRetry: () => _loadFavorites(reset: true),
      );
    }
    if (_favorites.isEmpty) {
      return _CharactersStatus(
        message: isArabic
            ? 'لا توجد شخصيات في المفضلة'
            : 'No favorite characters',
        icon: Icons.favorite_border_rounded,
      );
    }

    final extra = _favoritesLoading ? 1 : 0;
    return RefreshIndicator(
      onRefresh: () => _loadFavorites(reset: true),
      child: CatalogLtr(
        child: GridView.builder(
          controller: _favoritesController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
            context,
            maxCrossAxisExtent: 140,
            childAspectRatio: 0.58,
            crossAxisSpacing: 12,
            mainAxisSpacing: 14,
            handsetPortraitCrossAxisCount: 3,
          ),
          itemCount: _favorites.length + extra,
          itemBuilder: (context, index) {
            if (index >= _favorites.length) {
              return const AnimePosterShimmer();
            }
            final favorite = _favorites[index];
            return CharacterPosterCard(
              key: ValueKey('fav-${favorite.malId}'),
              character: favorite.asHit,
              onTap: () => _openCharacter(favorite.asHit),
            );
          },
        ),
      ),
    );
  }
}

class _CharacterSearchBar extends StatelessWidget {
  const _CharacterSearchBar({
    required this.controller,
    required this.focusNode,
    required this.searching,
    required this.hintText,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool searching;
  final String hintText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        Widget? suffix;
        if (searching) {
          suffix = Padding(
            padding: const EdgeInsets.all(14),
            child: SizedBox(
              width: 20,
              height: 20,
              child: AppLoadingIndicator(
                color: theme.colorScheme.primary,
                constraints: BoxConstraints.tight(const Size(20, 20)),
              ),
            ),
          );
        } else if (value.text.isNotEmpty) {
          suffix = IconButton(
            tooltip: 'Clear',
            icon: Icon(
              Icons.clear_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            onPressed: onClear,
          );
        }
        return Container(
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.92,
            ),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : theme.colorScheme.outlineVariant,
              width: 1.2,
            ),
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              textInputAction: TextInputAction.search,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              textDirection: searchTextDirection(
                value.text,
                fallback: TextDirection.rtl,
              ),
              textAlign: TextAlign.start,
              textAlignVertical: TextAlignVertical.center,
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurface,
              ),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                enabledBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 15,
                ),
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 46,
                  minHeight: 48,
                ),
                suffixIcon: suffix,
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 46,
                  minHeight: 48,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CharactersStatus extends StatelessWidget {
  const _CharactersStatus({
    required this.message,
    required this.icon,
    this.onRetry,
    this.actionLabel,
  });

  final String message;
  final IconData icon;
  final Future<void> Function()? onRetry;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => onRetry!(),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(actionLabel ?? 'إعادة المحاولة'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';

/// What search looks through. [all] searches the other four at once and
/// shows a few of each, with a way into the full list of any of them.
enum SearchDomain { all, anime, animation, manga, characters }

final class SearchDomainCapabilities {
  const SearchDomainCapabilities({
    required this.showSort,
    required this.showFilter,
  });

  final bool showSort;
  final bool showFilter;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchDomainCapabilities &&
          other.showSort == showSort &&
          other.showFilter == showFilter;

  @override
  int get hashCode => Object.hash(showSort, showFilter);
}

extension SearchDomainCapabilitiesExtension on SearchDomain {
  SearchDomainCapabilities get capabilities => switch (this) {
    SearchDomain.all => const SearchDomainCapabilities(
      showSort: false,
      showFilter: false,
    ),
    SearchDomain.anime => const SearchDomainCapabilities(
      showSort: true,
      showFilter: true,
    ),
    // Animation filters and sorts through the anime catalog, where it is
    // tagged.
    SearchDomain.animation => const SearchDomainCapabilities(
      showSort: true,
      showFilter: true,
    ),
    // Manga filters and sorts in the app: its index can do neither.
    SearchDomain.manga => const SearchDomainCapabilities(
      showSort: true,
      showFilter: true,
    ),
    SearchDomain.characters => const SearchDomainCapabilities(
      showSort: false,
      showFilter: false,
    ),
  };
}

final class SearchDomainNotifier extends Notifier<SearchDomain> {
  @override
  SearchDomain build() => SearchDomain.anime;

  void set(SearchDomain value) {
    if (state == value) return;
    state = value;
  }
}

final searchDomainProvider =
    NotifierProvider<SearchDomainNotifier, SearchDomain>(
      SearchDomainNotifier.new,
    );

/// What a search category is called, as the filter sheet lists it.
String searchDomainLabel(BuildContext context, SearchDomain domain) {
  final l10n = AppLocalizations.of(context);

  return switch (domain) {
    SearchDomain.all => 'الكل',
    SearchDomain.anime => l10n?.searchDomainAnime ?? 'أنمي',
    SearchDomain.animation => l10n?.searchDomainAnimation ?? 'انميشن',
    SearchDomain.manga => l10n?.searchDomainManga ?? 'مانجا',
    SearchDomain.characters => l10n?.searchDomainCharacters ?? 'شخصيات',
  };
}

IconData searchDomainIcon(SearchDomain domain) => switch (domain) {
  SearchDomain.all => Icons.apps_rounded,
  SearchDomain.anime => Icons.movie_rounded,
  SearchDomain.animation => Icons.animation_rounded,
  SearchDomain.manga => Icons.menu_book_rounded,
  SearchDomain.characters => Icons.groups_rounded,
};

/// The search field's hint, naming what is being searched.
String searchDomainHint(BuildContext context, SearchDomain domain) {
  return switch (domain) {
    SearchDomain.all => 'ابحث عن الكل',
    SearchDomain.anime => 'ابحث عن انمي',
    SearchDomain.animation => 'ابحث عن انميشن',
    SearchDomain.manga => 'ابحث عن مانجا',
    SearchDomain.characters => 'ابحث عن شخصيات',
  };
}

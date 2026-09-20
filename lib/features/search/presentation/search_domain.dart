import 'package:flutter_riverpod/flutter_riverpod.dart';

enum SearchDomain { anime, animation, manga, characters }

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
    SearchDomain.anime => const SearchDomainCapabilities(
      showSort: true,
      showFilter: true,
    ),
    SearchDomain.animation => const SearchDomainCapabilities(
      showSort: true,
      showFilter: true,
    ),
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

final searchDomainProvider = NotifierProvider<SearchDomainNotifier, SearchDomain>(
  SearchDomainNotifier.new,
);

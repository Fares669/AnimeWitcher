import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default search domain is anime', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(searchDomainProvider), SearchDomain.anime);
  });

  test('characters and all have nothing to filter', () {
    expect(
      SearchDomain.all.capabilities,
      const SearchDomainCapabilities(showSort: false, showFilter: false),
    );
    expect(
      SearchDomain.characters.capabilities,
      const SearchDomainCapabilities(showSort: false, showFilter: false),
    );
  });

  test('manga filters and sorts, in the app', () {
    expect(
      SearchDomain.manga.capabilities,
      const SearchDomainCapabilities(showSort: true, showFilter: true),
    );
  });

  test('animation filters and sorts through the anime catalog', () {
    expect(
      SearchDomain.animation.capabilities,
      const SearchDomainCapabilities(showSort: true, showFilter: true),
    );
  });
}

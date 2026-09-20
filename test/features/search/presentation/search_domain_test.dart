import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default search domain is anime', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(searchDomainProvider), SearchDomain.anime);
  });

  test('characters expose only the domain control', () {
    expect(
      SearchDomain.characters.capabilities,
      const SearchDomainCapabilities(showSort: false, showFilter: false),
    );
  });

  test('manga keeps its own sort and filter controls', () {
    expect(
      SearchDomain.manga.capabilities,
      const SearchDomainCapabilities(showSort: true, showFilter: true),
    );
  });
}

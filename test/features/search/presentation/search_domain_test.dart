import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('search UI labels stay Arabic in a non-Arabic host', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Column(
            children: [
              for (final domain in SearchDomain.values) ...[
                Text(searchDomainLabel(context, domain)),
                Text(searchDomainHint(context, domain)),
              ],
            ],
          ),
        ),
      ),
    );

    for (final label in ['الكل', 'أنمي', 'انميشن', 'مانجا', 'شخصيات']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('ابحث عن الكل'), findsOneWidget);
    expect(find.text('ابحث عن انمي'), findsOneWidget);
    expect(find.text('ابحث عن مانجا'), findsOneWidget);
  });

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

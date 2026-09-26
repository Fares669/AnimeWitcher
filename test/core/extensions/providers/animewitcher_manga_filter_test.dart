import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// A manga record shaped like the live catalog's.
Map<String, Object?> _hit({
  String type = 'مانهوا',
  String status = 'مستمر',
  String year = '2023',
  List<String> tags = const <String>['اكشن', 'خيال'],
}) => <String, Object?>{
  'type': type,
  'tags': tags,
  'details': <String, Object?>{'status': status, 'year': year},
};

bool _matches(Map<String, Object?> hit, ProviderSearchFilters filters) =>
    AnimeWitcherNativeProvider.mangaHitMatchesFilters(hit, filters);

void main() {
  test('no filters keeps everything', () {
    expect(_matches(_hit(), const ProviderSearchFilters()), isTrue);
  });

  test('status, type and year each match any one chosen value', () {
    expect(
      _matches(
        _hit(status: 'مكتمل'),
        const ProviderSearchFilters(statuses: {'مستمر', 'مكتمل'}),
      ),
      isTrue,
    );
    expect(
      _matches(
        _hit(type: 'مانجا'),
        const ProviderSearchFilters(types: {'مانهوا'}),
      ),
      isFalse,
    );
    expect(
      _matches(
        _hit(year: '2020'),
        const ProviderSearchFilters(years: {'2023'}),
      ),
      isFalse,
    );
  });

  test('every chosen genre must be there, as with anime', () {
    expect(
      _matches(_hit(), const ProviderSearchFilters(genres: {'اكشن', 'خيال'})),
      isTrue,
    );
    expect(
      _matches(_hit(), const ProviderSearchFilters(genres: {'اكشن', 'رعب'})),
      isFalse,
    );
  });

  test('the catalog spelling ى for ي still matches', () {
    expect(
      _matches(
        _hit(tags: const <String>['رومانسى']),
        const ProviderSearchFilters(genres: {'رومانسي'}),
      ),
      isTrue,
    );
  });

  group('sorting', () {
    final hits = <Map<String, Object?>>[
      {
        'name': 'Beta',
        'details': {'year': '2020'},
      },
      {
        'name': 'alpha',
        'details': {'year': '2023'},
      },
      {
        'name': 'Gamma',
        'details': {'year': ''},
      },
    ];
    List<String> names(List<Map<String, Object?>> list) =>
        list.map((hit) => '${hit['name']}').toList();

    test('by name, ignoring case', () {
      expect(
        names(AnimeWitcherNativeProvider.sortMangaHits(hits, 'name_asc')),
        ['alpha', 'Beta', 'Gamma'],
      );
      expect(
        names(AnimeWitcherNativeProvider.sortMangaHits(hits, 'name_desc')),
        ['Gamma', 'Beta', 'alpha'],
      );
    });

    test('by year, with no year last either way', () {
      expect(
        names(AnimeWitcherNativeProvider.sortMangaHits(hits, 'year_asc')),
        ['Beta', 'alpha', 'Gamma'],
      );
      expect(
        names(AnimeWitcherNativeProvider.sortMangaHits(hits, 'year_desc')),
        ['alpha', 'Beta', 'Gamma'],
      );
    });

    test('the default keeps the catalog order, most read first', () {
      expect(
        names(AnimeWitcherNativeProvider.sortMangaHits(hits, 'favorites')),
        ['Beta', 'alpha', 'Gamma'],
      );
    });
  });
}

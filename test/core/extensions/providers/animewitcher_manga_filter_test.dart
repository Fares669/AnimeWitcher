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

class _ObservedGenre {
  _ObservedGenre(this.value, this.observed, {this.failure = false});
  final String value;
  final List<String> observed;
  final bool failure;
  @override
  String toString() {
    observed.add(value);
    if (failure) throw StateError('Synthetic tag error');
    return value;
  }
}

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

  test('noncanonical field types preserve fallback and rejection', () {
    const filters = ProviderSearchFilters(
      statuses: {'مستمر'},
      years: {'2023'},
      genres: {' اكشن '},
    );
    expect(
      _matches(<String, Object?>{
        'details': <Object?, Object?>{'state': ' مستمر ', 'year': 2023},
        'tags': ['أكشن'],
      }, filters),
      isTrue,
    );
    expect(
      _matches(<String, Object?>{
        'details': {'status': 'مكتمل', 'state': 'مستمر', 'year': 2023},
        'tags': ['أكشن'],
      }, filters),
      isFalse,
    );
    expect(
      _matches(<String, Object?>{
        'details': {'state': 'مستمر', 'year': 2023},
      }, filters),
      isFalse,
    );
    expect(
      () => _matches(<String, Object?>{
        'details': <Object?, Object?>{123: 'not a string key'},
      }, filters),
      throwsA(isA<TypeError>()),
    );
  });

  test('one normalized genre preserves Arabic spelling and exact coercion', () {
    final row = <String, Object?>{
      'tags': <Object?>['  إكشن ', 'رومانسى', null, 42, '  '],
    };
    for (final selected in <Set<String>>[
      {'اكشن'},
      {'أكشن', 'إكشن'},
      {'رومانسي'},
      {'null'},
      {'42'},
      {''},
      {'اكشن', 'رومانسي'},
      <String>{},
    ]) {
      expect(
        _matches(row, ProviderSearchFilters(genres: selected)),
        isTrue,
        reason: '$selected',
      );
    }
    for (final selected in <Set<String>>[
      {'غير معروف'},
      {'أَكشن'},
      {'رومانسي', 'غير معروف'},
    ]) {
      expect(
        _matches(row, ProviderSearchFilters(genres: selected)),
        isFalse,
        reason: '$selected',
      );
    }
    for (final malformed in <Object?>[
      null,
      'اكشن',
      42,
      {'اكشن': true},
    ]) {
      expect(
        _matches({
          'tags': malformed,
        }, const ProviderSearchFilters(genres: {'اكشن'})),
        isFalse,
      );
      expect(
        _matches({
          'tags': malformed,
        }, const ProviderSearchFilters(sort: 'sort-not-known')),
        isTrue,
      );
    }
  });

  test(
    'single genre visits tags after a match without remembering raw lists',
    () {
      final observed = <String>[];
      final tags = <Object?>[
        _ObservedGenre('أكشن', observed),
        _ObservedGenre('tail', observed, failure: true),
      ];
      final row = <String, Object?>{'tags': tags};
      const filter = ProviderSearchFilters(genres: {'اكشن'});
      expect(() => _matches(row, filter), throwsStateError);
      expect(observed, ['أكشن', 'tail']);
      tags[1] = 'دراما';
      expect(_matches(row, filter), isTrue);
      tags[0] = 'خيال';
      expect(_matches(row, filter), isFalse);
    },
  );

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

    test('cached sort keys do not change raw item identity or tie order', () {
      final data = <Map<String, Object?>>[
        for (var i = 0; i < 100; i++)
          {
            'manga_name': <String>['  beta  ', ' ALPHA ', 'أكشن'][i % 3],
            'details': {
              'year': <Object?>[2020, '2021', '0', null, 'bad'][i % 5],
            },
          },
      ];
      final inputBefore = List<Map<String, Object?>>.of(data);
      String nameOf(Map<String, Object?> hit) =>
          '${hit['manga_name']}'.trim().toLowerCase();
      int? yearOf(Map<String, Object?> hit) {
        final rawDetails = hit['details'] as Map;
        final year = int.tryParse('${rawDetails['year'] ?? ''}');
        return year == null || year <= 0 ? null : year;
      }

      for (final sort in ['name_asc', 'name_desc', 'year_asc', 'year_desc']) {
        final expected = List<Map<String, Object?>>.of(data);
        final ascending = sort.endsWith('_asc');
        if (sort.startsWith('name_')) {
          expected.sort(
            (a, b) => ascending
                ? nameOf(a).compareTo(nameOf(b))
                : nameOf(b).compareTo(nameOf(a)),
          );
        } else {
          expected.sort((a, b) {
            final ya = yearOf(a), yb = yearOf(b);
            if (ya == null) return yb == null ? 0 : 1;
            if (yb == null) return -1;
            return ascending ? ya.compareTo(yb) : yb.compareTo(ya);
          });
        }
        final actual = AnimeWitcherNativeProvider.sortMangaHits(data, sort);
        expect(
          Iterable<int>.generate(data.length)
              .every((i) => identical(actual[i], expected[i])),
          isTrue,
          reason: sort,
        );
      }
      expect(data, orderedEquals(inputBefore));
    });
  });
}

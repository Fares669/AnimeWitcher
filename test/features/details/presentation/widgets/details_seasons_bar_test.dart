import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_seasons_bar.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item(String url, {String? type, int? year}) => MultimediaItem(
  title: url,
  url: url,
  posterUrl: '',
  contentType: MultimediaContentType.anime,
  relationType: type,
  year: year,
);

void main() {
  final current = _item('s2', year: 2022);

  test('no bar for a show with nothing in the same story', () {
    expect(seasonsBarEntries(current, const []), isEmpty);
    expect(
      seasonsBarEntries(current, [
        _item('spin', type: 'SPIN_OFF'),
        _item('alt', type: 'ALTERNATIVE_VERSION'),
      ]),
      isEmpty,
    );
  });

  test('before, the current one, after, then side stories', () {
    final entries = seasonsBarEntries(current, [
      _item('ova', type: 'SIDE_STORY', year: 2021),
      _item('s3', type: 'SEQUEL', year: 2024),
      _item('s1', type: 'PREQUEL', year: 2020),
      _item('spin', type: 'SPIN_OFF', year: 2023),
    ]);
    expect(entries.map((e) => e.item.url), ['s1', 's2', 's3', 'ova']);
    expect(entries.map((e) => e.isCurrent), [false, true, false, false]);
  });

  test('duplicates and the page itself are listed once', () {
    final entries = seasonsBarEntries(current, [
      _item('s1', type: 'PREQUEL'),
      _item('s1', type: 'PREQUEL'),
      _item('s2', type: 'SEQUEL'),
    ]);
    expect(entries.map((e) => e.item.url), ['s1', 's2']);
  });

  test('series are numbered as seasons; other types keep their name', () {
    MultimediaItem typed(String url, String type) =>
        MultimediaItem(title: url, url: url, posterUrl: '', catalogType: type);
    expect(
      seasonsBarLabels([
        typed('a', 'مسلسل'),
        typed('b', 'فيلم'),
        typed('c', 'مسلسل'),
        typed('d', 'اوفا'),
        typed('e', 'فيلم'),
      ]),
      ['الموسم 1', 'فيلم 1', 'الموسم 2', 'اوفا', 'فيلم 2'],
    );
  });

  test('season and part numbers come from the title', () {
    MultimediaItem s(String title, {String type = 'مسلسل'}) => MultimediaItem(
      title: title,
      url: title,
      posterUrl: '',
      catalogType: type,
    );
    expect(
      seasonsBarLabels([
        s('Tensei shitara Slime Datta Ken'),
        s('Tensei shitara Slime Datta Ken: Coleus no Yume', type: 'اوفا'),
        s('Tensei shitara Slime Datta Ken 2nd Season'),
        s('Tensei shitara Slime Datta Ken 2nd Season Part 2'),
        s('Tensei shitara Slime Datta Ken 3rd Season'),
        s('Tensei shitara Slime Datta Ken 4th Season'),
      ]),
      [
        'الموسم 1',
        'Coleus no Yume',
        'الموسم 2',
        'الموسم 2 - الجزء 2',
        'الموسم 3',
        'الموسم 4',
      ],
    );
    // No number in the title: count on from the season before.
    expect(
      seasonsBarLabels([
        s('Shingeki no Kyojin'),
        s('Shingeki no Kyojin Season 3'),
        s('Shingeki no Kyojin: The Final Season'),
        s('Shingeki no Kyojin: The Final Season Part 2'),
      ]),
      ['الموسم 1', 'الموسم 3', 'الموسم 4', 'الموسم 4 - الجزء 2'],
    );
  });

  test('movies and OVAs that only link upwards are found by name', () async {
    MultimediaItem t(String url, String title, String type, {String? rel}) =>
        MultimediaItem(
          title: title,
          url: url,
          posterUrl: '',
          catalogType: type,
          relationType: rel,
        );
    final s1 = t('s1', 'Tensei shitara Slime Datta Ken', 'مسلسل');
    final entries = await walkSeasonsBar(
      current: s1,
      related: [
        t(
          's2',
          'Tensei shitara Slime Datta Ken 2nd Season',
          'مسلسل',
          rel: 'SEQUEL',
        ),
      ],
      fetchRelated: (_) async => const [],
      searchFranchise: (_) async => [
        t(
          'movie',
          'Tensei shitara Slime Datta Ken Movie: Guren no Kizuna-hen',
          'فيلم',
        ),
        t('ova', 'Tensei shitara Slime Datta Ken OVA', 'اوفا'),
        t('s2', 'Tensei shitara Slime Datta Ken 2nd Season', 'مسلسل'),
        t('other', 'Some Other Show', 'فيلم'),
      ],
    );
    expect(entries.map((e) => e.item.url), ['s1', 's2', 'movie', 'ova']);
    expect(entries.map((e) => e.label), [
      'الموسم 1',
      'الموسم 2',
      'Movie: Guren no Kizuna-hen',
      'OVA',
    ]);
  });

  test('entries carry their short name', () {
    final entries = seasonsBarEntries(current, [
      _item('s3', type: 'SEQUEL', year: 2024),
      _item('s1', type: 'PREQUEL', year: 2020),
    ]);
    expect(entries.map((e) => e.label), ['الموسم 1', 'الموسم 2', 'الموسم 3']);
  });

  test('an unknown stored style falls back to cards', () {
    expect(SeasonsBarStyle.fromName(null), SeasonsBarStyle.cards);
    expect(SeasonsBarStyle.fromName('pills'), SeasonsBarStyle.pills);
    expect(SeasonsBarStyle.fromName('tabs'), SeasonsBarStyle.cards);
  });

  group('walking the franchise', () {
    // Bungou Stray Dogs as the catalog relates it: each season names only
    // its neighbours, and the movie and OVA hang off season two.
    final graph = <String, List<MultimediaItem>>{
      's1': [_item('s2', type: 'SEQUEL', year: 2016)],
      's2': [
        _item('s1', type: 'PREQUEL', year: 2016),
        _item('s3', type: 'SEQUEL', year: 2019),
        _item('ova', type: 'SIDE_STORY', year: 2017),
        _item('movie', type: 'SIDE_STORY', year: 2018),
      ],
      's3': [
        _item('s2', type: 'PREQUEL', year: 2016),
        _item('s4', type: 'SEQUEL', year: 2023),
      ],
      's4': [_item('s3', type: 'PREQUEL', year: 2019)],
      'ova': [_item('s2', type: 'PARENT', year: 2016)],
    };
    Future<List<MultimediaItem>> fetch(String url) async => graph[url] ?? [];

    test('season one shows every season, not only season two', () async {
      final entries = await walkSeasonsBar(
        current: _item('s1', year: 2016),
        related: graph['s1']!,
        fetchRelated: fetch,
      );
      expect(entries.map((e) => e.item.url), [
        's1',
        's2',
        's3',
        's4',
        'ova',
        'movie',
      ]);
      expect(entries.first.isCurrent, isTrue);
    });

    test('a side story walks from its parent', () async {
      final entries = await walkSeasonsBar(
        current: _item('ova', year: 2017),
        related: graph['ova']!,
        fetchRelated: fetch,
      );
      expect(entries.map((e) => e.item.url), [
        's1',
        's2',
        's3',
        's4',
        'ova',
        'movie',
      ]);
      expect(entries.where((e) => e.isCurrent).single.item.url, 'ova');
    });

    test('a season that fails to answer shortens the bar only', () async {
      final entries = await walkSeasonsBar(
        current: _item('s1', year: 2016),
        related: graph['s1']!,
        fetchRelated: (url) async =>
            url == 's3' ? throw Exception('offline') : graph[url] ?? [],
      );
      expect(entries.map((e) => e.item.url), [
        's1',
        's2',
        's3',
        'ova',
        'movie',
      ]);
    });

    test('a spin-off series shows the main seasons first', () async {
      MultimediaItem titled(String url, String title, {String? type}) =>
          MultimediaItem(
            title: title,
            url: url,
            posterUrl: '',
            contentType: MultimediaContentType.anime,
            relationType: type,
          );
      final spinOffGraph = <String, List<MultimediaItem>>{
        ...graph,
        's1': [titled('s2', 'Bungou Stray Dogs 2nd Season', type: 'SEQUEL')],
        'wan': [
          titled('wan2', 'Bungou Stray Dogs Wan! 2', type: 'SEQUEL'),
          titled('s1', 'Bungou Stray Dogs', type: 'PARENT'),
        ],
        'wan2': [titled('wan', 'Bungou Stray Dogs Wan!', type: 'PREQUEL')],
      };
      final entries = await walkSeasonsBar(
        current: titled('wan2', 'Bungou Stray Dogs Wan! 2'),
        related: spinOffGraph['wan2']!,
        fetchRelated: (url) async => spinOffGraph[url] ?? [],
      );
      expect(entries.map((e) => e.item.url), [
        's1',
        's2',
        's3',
        's4',
        'wan',
        'wan2',
        'ova',
        'movie',
      ]);
      expect(entries.map((e) => e.label).take(6), [
        'الموسم 1',
        'الموسم 2',
        'الموسم 3',
        'الموسم 4',
        'Wan!',
        'Wan! 2',
      ]);
      expect(entries.where((e) => e.isCurrent).single.item.url, 'wan2');

      // The main series names Wan! as a spin-off; its seasons must show
      // from a main season's page too, not only from Wan!'s own.
      final withSpinOffLink = <String, List<MultimediaItem>>{
        ...spinOffGraph,
        's1': [
          ...spinOffGraph['s1']!,
          titled('wan', 'Bungou Stray Dogs Wan!', type: 'SPIN_OFF'),
        ],
      };
      final fromSeason3 = await walkSeasonsBar(
        current: titled('s3', 'Bungou Stray Dogs 3rd Season'),
        related: withSpinOffLink['s3']!,
        fetchRelated: (url) async => withSpinOffLink[url] ?? [],
      );
      expect(fromSeason3.map((e) => e.item.url), [
        's1',
        's2',
        's3',
        's4',
        'wan',
        'wan2',
        'ova',
        'movie',
      ]);
      expect(fromSeason3.where((e) => e.isCurrent).single.item.url, 's3');
    });

    test('the walk stops after its fetch budget', () async {
      var calls = 0;
      await walkSeasonsBar(
        current: _item('s0'),
        related: [_item('s1', type: 'SEQUEL')],
        fetchRelated: (url) async {
          calls++;
          final n = int.parse(url.substring(1));
          return [_item('s${n + 1}', type: 'SEQUEL')];
        },
        maxFetches: 5,
      );
      expect(calls, 5);
    });
  });

  test('relation types are matched whatever their case', () {
    final entries = seasonsBarEntries(current, [_item('s3', type: 'sequel')]);
    expect(entries.map((e) => e.item.url), ['s2', 's3']);
  });
}

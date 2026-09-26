import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_browse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<Episode> _episodes(int count, {bool newestFirst = false}) {
  final list = <Episode>[
    for (var i = 1; i <= count; i++)
      Episode(name: 'الحلقة $i', url: 'ep://$i', season: 1, episode: i),
  ];
  return newestFirst ? list.reversed.toList() : list;
}

void main() {
  setUp(resetEpisodeBrowse);

  group('blocks', () {
    test('a short series has no blocks', () {
      expect(episodeRangesApply(100), isFalse);
      expect(episodeRangesApply(101), isTrue);
    });

    test('a hundred to a block, numbered from the first episode', () {
      final ranges = episodeRanges(_episodes(1122, newestFirst: true));
      expect(ranges, hasLength(12));
      expect(episodeRangeLabel(ranges.first), '1–100');
      expect(episodeRangeLabel(ranges[8]), '801–900');
      expect(episodeRangeLabel(ranges.last), '1101–1122');
    });

    test('a block keeps the list in its own order', () {
      final ordered = _episodes(1122, newestFirst: true);
      final shown = browseEpisodes(
        ordered: ordered,
        rangeIndex: 8,
        filter: EpisodeListFilter.all,
        isWatched: (_) => false,
        isDownloaded: (_) => false,
      );
      expect(shown, hasLength(100));
      expect(shown.first.episode, 900);
      expect(shown.last.episode, 801);
    });

    test('a block past the end shows every episode', () {
      final ordered = _episodes(150);
      final shown = browseEpisodes(
        ordered: ordered,
        rangeIndex: 7,
        filter: EpisodeListFilter.all,
        isWatched: (_) => false,
        isDownloaded: (_) => false,
      );
      expect(shown, hasLength(150));
    });
  });

  group('filters', () {
    test('unwatched and downloaded, inside the chosen block', () {
      final ordered = _episodes(300);
      bool watched(Episode e) => e.episode <= 150;
      bool downloaded(Episode e) => e.episode % 50 == 0;

      final unwatched = browseEpisodes(
        ordered: ordered,
        rangeIndex: 1,
        filter: EpisodeListFilter.unwatched,
        isWatched: watched,
        isDownloaded: downloaded,
      );
      expect(unwatched.first.episode, 151);
      expect(unwatched, hasLength(50));

      final saved = browseEpisodes(
        ordered: ordered,
        rangeIndex: null,
        filter: EpisodeListFilter.downloaded,
        isWatched: watched,
        isDownloaded: downloaded,
      );
      expect(saved.map((e) => e.episode), <int>[50, 100, 150, 200, 250, 300]);
    });
  });

  group('bar', () {
    Future<void> pump(WidgetTester tester, int count) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EpisodeBrowseBar(episodes: _episodes(count)),
        ),
      ),
    );

    testWidgets('no block menu for a short series', (tester) async {
      await pump(tester, 24);
      expect(
        find.byKey(const ValueKey<String>('episode-range-menu')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('episode-filter-unwatched')),
        findsOneWidget,
      );
    });

    testWidgets('a block and a filter picked from the bar', (tester) async {
      await pump(tester, 1122);
      await tester.tap(
        find.byKey(const ValueKey<String>('episode-range-menu')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('episode-range-8')));
      await tester.pumpAndSettle();
      expect(episodeRangeIndex.value, 8);
      expect(find.text('Episodes 801–900'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('episode-filter-downloaded')),
      );
      await tester.pump();
      expect(episodeListFilter.value, EpisodeListFilter.downloaded);
    });
  });
}

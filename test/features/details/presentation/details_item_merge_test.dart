import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/details_item_merge.dart';

final class _MeasuredArtworkEpisode extends Episode {
  _MeasuredArtworkEpisode(int index, {super.posterUrl})
    : super(name: 'Episode $index', url: 'episode://$index', episode: index);

  int posterReads = 0;

  @override
  String? get posterUrl {
    posterReads++;
    return super.posterUrl;
  }
}

void main() {
  group('Details route item merge', () {
    final title = MultimediaItem(
      title: 'Catalog',
      url: 'anime://catalog',
      posterUrl: 'https://images.example/title.jpg',
    );

    test('reuses the merge until an input really changes', () {
      final merge = DetailsRouteItemMerge();
      final headers = {'Referer': 'original'};
      final catalog = [
        for (var i = 1; i <= 4; i++)
          Episode(
            name: 'Episode $i',
            url: 'episode://$i',
            episode: i,
            headers: headers,
          ),
      ];
      MultimediaItem render([MultimediaItem? incoming]) => merge.resolve(
        fallback: title,
        incoming: incoming ?? title,
        episodes: catalog,
      );

      final first = render();
      expect(render(), same(first));
      // Nested records already shared by the existing merge stay live.
      headers['Referer'] = 'renewed';
      expect(render(), same(first));
      expect(first.episodes!.first.headers!['Referer'], 'renewed');

      final oldEpisode = catalog[1];
      catalog[1] = oldEpisode.copyWith(description: 'new episode metadata');
      expect(catalog[1], oldEpisode); // Episode equality ignores description.
      final edited = render();
      expect(edited, isNot(same(first)));
      expect(edited.episodes![1], same(catalog[1]));
      expect(render(), same(edited));

      edited.episodes!.removeLast();
      final repaired = render();
      expect(repaired, isNot(same(edited)));
      expect(repaired.episodes, orderedEquals(catalog));

      // MultimediaItem equality also ignores cast; a replacement can share
      // the catalog and identity fields while changing UI data.
      final actors = [Actor(name: 'New character')];
      final withCast = title.copyWith(cast: actors);
      expect(withCast, title);
      final castResult = render(withCast);
      expect(castResult, isNot(same(repaired)));
      expect(castResult.cast, same(actors));
      expect(render(withCast), same(castResult));

      final newCard = title.copyWith(description: 'An updated opening card');
      expect(newCard, title);
      expect(
        merge.resolve(fallback: newCard, incoming: withCast, episodes: catalog)
            .description,
        newCard.description,
      );
    });

    test('remerges duplicate and noncanonical episode order', () {
      final merge = DetailsRouteItemMerge();
      final catalog = [
        Episode(name: 'Regular', url: 'episode://1', season: 1, episode: 1),
        Episode(name: 'Dubbed', url: 'episode://1-dub', season: 1, episode: 1),
        Episode(name: 'Later', url: 'episode://2', season: 1, episode: 2),
      ];
      MultimediaItem render() =>
          merge.resolve(fallback: title, incoming: title, episodes: catalog);
      final first = render();
      expect(render(), isNot(same(first)));
      catalog[0] = catalog[2];
      catalog[2] = first.episodes!.first;
      final updated = render();
      expect(
        updated.episodes!.map((e) => e.url),
        orderedEquals(
          mergeDetailsItem(
            fallback: title,
            incoming: title,
            episodes: catalog,
          ).episodes!.map((e) => e.url),
        ),
      );
      expect(render(), isNot(same(updated)));
    });

    test('resolves renewed episode artwork if title artwork is absent', () {
      final merge = DetailsRouteItemMerge();
      final sparse = title.copyWith(
        posterUrl: 'none',
        bannerUrl: 'https://images.example/banner.jpg',
      );
      final catalog = [
        Episode(name: 'One', url: 'episode://1', episode: 1),
        Episode(name: 'Two', url: 'episode://2', episode: 2),
      ];
      MultimediaItem render() =>
          merge.resolve(fallback: sparse, incoming: sparse, episodes: catalog);
      expect(render().posterUrl, sparse.bannerUrl);
      catalog[0] = catalog[0].copyWith(posterUrl: title.posterUrl);
      expect(render().posterUrl, title.posterUrl);
    });
  });

  group('mergeDetailsItem', () {
    test('keeps card artwork when a sparse details response has none', () {
      final card = MultimediaItem(
        title: 'Movie',
        url: 'anime://movie',
        posterUrl: 'https://images.example/poster.jpg',
        bannerUrl: 'https://images.example/banner.jpg',
      );
      final details = MultimediaItem(
        title: 'Movie',
        url: card.url,
        posterUrl: '',
      );

      final result = mergeDetailsItem(fallback: card, incoming: details);

      expect(result.posterUrl, card.posterUrl);
      expect(result.bannerUrl, card.bannerUrl);
    });

    test('uses one episode thumbnail when all title artwork is missing', () {
      final item = MultimediaItem(
        title: 'One episode title',
        url: 'anime://one-episode',
        posterUrl: '',
      );
      final episode = Episode(
        name: 'Episode 1',
        url: 'episode://1',
        episode: 1,
        posterUrl: 'https://images.example/episode.jpg',
      );

      final result = mergeDetailsItem(
        fallback: item,
        incoming: item,
        episodes: <Episode>[episode],
      );

      expect(result.posterUrl, episode.posterUrl);
      expect(result.bannerUrl, episode.posterUrl);
    });

    test('prefers complete details artwork over the opening card', () {
      final card = MultimediaItem(
        title: 'Title',
        url: 'anime://title',
        posterUrl: 'https://images.example/card.jpg',
      );
      final details = MultimediaItem(
        title: 'Title',
        url: card.url,
        posterUrl: 'https://images.example/details.jpg',
        bannerUrl: 'https://images.example/details-banner.jpg',
      );

      final result = mergeDetailsItem(fallback: card, incoming: details);

      expect(result.posterUrl, details.posterUrl);
      expect(result.bannerUrl, details.bannerUrl);
    });

    test('title posters skip every episode-artwork lookup', () {
      final episodes = List.generate(1200, _MeasuredArtworkEpisode.new);
      final card = MultimediaItem(
        title: 'Title',
        url: 'anime://title',
        posterUrl: 'https://images.example/card.jpg',
        fullPosterUrl: 'https://images.example/full-card.jpg',
      );
      final details = card.copyWith(
        posterUrl: 'https://images.example/details.jpg',
        bannerUrl: 'https://images.example/banner.jpg',
      );
      final sparse = details.copyWith(posterUrl: ' undefined ');
      final result = mergeDetailsItem(
        fallback: card,
        incoming: details,
        episodes: episodes,
      );
      final cardFallback = mergeDetailsItem(
        fallback: card,
        incoming: sparse,
        episodes: episodes,
      );

      expect(result.posterUrl, details.posterUrl);
      expect(cardFallback.posterUrl, card.posterUrl);
      expect(cardFallback.bannerUrl, details.bannerUrl);
      expect(cardFallback.posterViewerUrl, card.fullPosterUrl);
      expect(result.episodes, orderedEquals(episodes));
      expect(cardFallback.episodes, orderedEquals(episodes));
      final reads = episodes.fold(0, (sum, row) => sum + row.posterReads);
      // A catalog with no stills used to be read in full even though the
      // details or card already supplied the poster.
      expect(reads, 0);
    });

    test(
      'usable stills still outrank banners when both posters are missing',
      () {
        final episodes = [
          _MeasuredArtworkEpisode(0, posterUrl: ' null '),
          _MeasuredArtworkEpisode(1, posterUrl: 'https://images.example/1.jpg'),
          _MeasuredArtworkEpisode(2, posterUrl: 'https://images.example/2.jpg'),
        ];
        final card = MultimediaItem(
          title: 'Title',
          url: 'anime://title',
          posterUrl: 'none',
          bannerUrl: 'https://images.example/card-banner.jpg',
          episodes: episodes,
        );
        final details = card.copyWith(
          posterUrl: ' ',
          bannerUrl: 'https://images.example/details-banner.jpg',
        );

        final result = mergeDetailsItem(fallback: card, incoming: details);

        expect(result.posterUrl, 'https://images.example/1.jpg');
        expect(result.bannerUrl, details.bannerUrl);
        expect(result.posterViewerUrl, result.posterUrl);
        expect(result.episodes, orderedEquals(episodes));
        expect(episodes.map((row) => row.posterReads), [1, 1, 0]);
      },
    );

    test('ignores serialized null artwork values', () {
      final card = MultimediaItem(
        title: 'Title',
        url: 'anime://title',
        posterUrl: 'https://images.example/card.jpg',
      );
      final details = MultimediaItem(
        title: 'Title',
        url: card.url,
        posterUrl: 'null',
        bannerUrl: 'undefined',
      );

      final result = mergeDetailsItem(fallback: card, incoming: details);

      expect(result.posterUrl, card.posterUrl);
      expect(result.bannerUrl, card.posterUrl);
    });

    test(
      'keeps the card large poster when details only repeat the catalog artwork',
      () {
        final card = MultimediaItem(
          title: 'Title',
          url: 'anime://title',
          posterUrl: 'https://images.example/medium.jpg',
          fullPosterUrl: 'https://images.example/large.jpg',
        );
        final details = MultimediaItem(
          title: 'Title',
          url: card.url,
          posterUrl: 'https://images.example/medium.jpg',
          fullPosterUrl: 'https://images.example/medium.jpg',
        );

        final result = mergeDetailsItem(fallback: card, incoming: details);

        expect(result.posterUrl, card.posterUrl);
        expect(result.fullPosterUrl, card.fullPosterUrl);
        expect(result.posterViewerUrl, card.fullPosterUrl);
      },
    );

    test('prefers a larger details poster over the opening card', () {
      final card = MultimediaItem(
        title: 'Title',
        url: 'anime://title',
        posterUrl: 'https://images.example/medium.jpg',
        fullPosterUrl: 'https://images.example/large.jpg',
      );
      final details = MultimediaItem(
        title: 'Title',
        url: card.url,
        posterUrl: 'https://images.example/medium.jpg',
        fullPosterUrl: 'https://images.example/original.jpg',
      );

      final result = mergeDetailsItem(fallback: card, incoming: details);

      expect(result.posterUrl, details.posterUrl);
      expect(result.fullPosterUrl, details.fullPosterUrl);
      expect(result.posterViewerUrl, details.fullPosterUrl);
    });

    test(
      'keeps a high-quality details poster when it matches fullPosterUrl',
      () {
        final card = MultimediaItem(
          title: 'Title',
          url: 'anime://title',
          posterUrl: 'https://images.example/medium.jpg',
        );
        final details = MultimediaItem(
          title: 'Title',
          url: card.url,
          posterUrl: 'https://images.example/large.jpg',
          fullPosterUrl: 'https://images.example/large.jpg',
        );

        final result = mergeDetailsItem(fallback: card, incoming: details);

        expect(result.posterUrl, details.posterUrl);
        expect(result.fullPosterUrl, details.fullPosterUrl);
        expect(result.posterViewerUrl, details.fullPosterUrl);
      },
    );
  });
}

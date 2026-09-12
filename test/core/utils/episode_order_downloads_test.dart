import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/utils/episode_order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Episode episode(int number, {int season = 1}) => Episode(
    name: 'Episode $number',
    url: 'https://example.test/$season/$number',
    season: season,
    episode: number,
  );

  test('downloaded episode items ignore download order and follow episode order', () {
    final downloadedOrder = [episode(10), episode(12), episode(11)];

    final ascending = episodeItemsInDisplayOrder(
      downloadedOrder,
      episodeOf: (item) => item,
      ascending: true,
    );
    final descending = episodeItemsInDisplayOrder(
      downloadedOrder,
      episodeOf: (item) => item,
      ascending: false,
    );

    expect(ascending.map((item) => item.episode), [10, 11, 12]);
    expect(descending.map((item) => item.episode), [12, 11, 10]);
  });

  test('downloaded episode items keep season order before episode number', () {
    final downloadedOrder = [episode(1, season: 2), episode(12), episode(11)];

    final ascending = episodeItemsInDisplayOrder(
      downloadedOrder,
      episodeOf: (item) => item,
      ascending: true,
    );

    expect(
      ascending.map((item) => (item.season, item.episode)),
      [(1, 11), (1, 12), (2, 1)],
    );
  });
}

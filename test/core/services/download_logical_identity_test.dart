import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_logical_identity.dart';

void main() {
  MultimediaItem item({
    String url = 'https://animewitcher.com/watch/123?ref=home',
    String title = 'Title A',
    String? provider = 'AnimeWitcher',
    int? tmdbId,
    String? imdbId,
    Map<String, String>? syncData = const {'malId': '999'},
    bool isDubbed = false,
  }) {
    return MultimediaItem(
      title: title,
      url: url,
      posterUrl: '',
      provider: provider,
      tmdbId: tmdbId,
      imdbId: imdbId,
      syncData: syncData,
      isDubbed: isDubbed,
      contentType: MultimediaContentType.anime,
    );
  }

  Episode episode({
    String url = 'https://cdn.example/temporary-episode-link-a',
    String name = 'الحلقة 12',
    int season = 1,
    int number = 12,
    DubStatus dubStatus = DubStatus.subbed,
  }) {
    return Episode(
      name: name,
      url: url,
      season: season,
      episode: number,
      dubStatus: dubStatus,
    );
  }

  group('DownloadLogicalIdentity', () {
    test('ignores execution URL, labels and task-attempt details', () {
      final first = DownloadLogicalIdentity.fromMedia(
        item: item(title: 'Localized title A'),
        episode: episode(
          url: 'https://signed.example/a?token=old',
          name: 'Episode Twelve',
        ),
      );
      final refreshed = DownloadLogicalIdentity.fromMedia(
        item: item(title: 'عنوان مترجم مختلف'),
        episode: episode(
          url: 'https://other-cdn.example/b?token=new',
          name: 'الحلقة الثانية عشر والأخيرة',
        ),
      );

      expect(refreshed.key, first.key);
      expect(first.key, isNot(contains('signed.example')));
      expect(first.key, isNot(contains('Episode Twelve')));
    });

    test('same filename cannot collapse different episodes', () {
      final ep12 = DownloadLogicalIdentity.fromMedia(
        item: item(),
        episode: episode(number: 12),
      );
      final ep13 = DownloadLogicalIdentity.fromMedia(
        item: item(),
        episode: episode(number: 13),
      );

      expect(ep12.key, isNot(ep13.key));
    });

    test('dub/sub variants remain distinct logical downloads', () {
      final sub = DownloadLogicalIdentity.fromMedia(
        item: item(),
        episode: episode(dubStatus: DubStatus.subbed),
      );
      final dub = DownloadLogicalIdentity.fromMedia(
        item: item(isDubbed: true),
        episode: episode(dubStatus: DubStatus.dubbed),
      );

      expect(sub.key, isNot(dub.key));
    });

    test('stable external ids outrank mutable catalog URL details', () {
      final oldRoute = DownloadLogicalIdentity.fromMedia(
        item: item(url: 'https://animewitcher.com/watch/old-route?x=1'),
        episode: episode(),
      );
      final newRoute = DownloadLogicalIdentity.fromMedia(
        item: item(url: 'https://animewitcher.com/watch/new-route?x=2'),
        episode: episode(),
      );

      expect(newRoute.key, oldRoute.key);
    });

    test('fallback content URL is canonicalized without query or fragment', () {
      final first = DownloadLogicalIdentity.fromMedia(
        item: item(
          url: 'HTTPS://Example.COM/anime/abc/?utm_source=x#player',
          syncData: null,
          tmdbId: null,
          imdbId: null,
        ),
        episode: episode(),
      );
      final second = DownloadLogicalIdentity.fromMedia(
        item: item(
          url: 'https://example.com/anime/abc',
          syncData: null,
          tmdbId: null,
          imdbId: null,
        ),
        episode: episode(),
      );

      expect(second.key, first.key);
    });

    test('different logical content never collapses by episode number', () {
      final a = DownloadLogicalIdentity.fromMedia(
        item: item(syncData: const {'malId': '999'}),
        episode: episode(number: 1),
      );
      final b = DownloadLogicalIdentity.fromMedia(
        item: item(syncData: const {'malId': '1000'}),
        episode: episode(number: 1),
      );

      expect(a.key, isNot(b.key));
    });
  });
}

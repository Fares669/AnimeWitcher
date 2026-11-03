import 'dart:convert';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/provider_local_history.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Memory extends StorageService {
  final values = <String, String>{'legacy_native_history': 'untouched'};
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String? value) async {
    await Future<void>.delayed(Duration.zero);
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

void main() {
  test('progress, continue watching and history survive restart without mixing providers', () async {
    final storage = _Memory();
    final rift = ProviderLocalHistory(storage, 'rift');
    final other = ProviderLocalHistory(storage, 'other');
    final item = MultimediaItem(
      title: 'Anime',
      url: 'same',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
    );
    await Future.wait([
      rift.recordOpened(item, episodeUrl: 'episode'),
      other.saveProgress(item, 9, 100, episodeUrl: 'episode'),
    ]);
    await rift.saveProgress(item, 30, 100, episodeUrl: 'episode');
    final restored = ProviderLocalHistory(storage, 'rift');
    expect(restored.history().single.item.provider, 'rift');
    expect(restored.continueWatching().single.position, 30);
    expect(restored.position('same', 'episode'), 30);
    expect(other.position('same', 'episode'), 9);
    await restored.clearContinueWatching();
    expect(restored.continueWatching(), isEmpty);
    expect(restored.history(), hasLength(1));
    expect(other.continueWatching(), hasLength(1));
    expect(storage.values['legacy_native_history'], 'untouched');
  });
  test(
    'watched episode states are isolated by source and survive restart',
    () async {
      final storage = _Memory();
      final rift = ProviderLocalHistory(storage, 'rift');
      final other = ProviderLocalHistory(storage, 'other');
      final episode = Episode(name: 'Episode', url: 'same');
      await rift.setWatched('anime', episode, true);
      expect(
        ProviderLocalHistory(storage, 'rift').isWatched('anime', episode),
        isTrue,
      );
      expect(other.isWatched('anime', episode), isNull);
      await rift.setWatched('anime', episode, false);
      expect(rift.isWatched('anime', episode), isFalse);
    },
  );

  test('invalid stored history is not overwritten', () async {
    final storage = _Memory();
    final history = ProviderLocalHistory(storage, 'rift');
    storage.values[history.storageKey] = '{broken';
    await expectLater(
      history.recordOpened(
        MultimediaItem(title: 'x', url: 'id', posterUrl: ''),
      ),
      throwsFormatException,
    );
    expect(storage.values[history.storageKey], '{broken');
  });

  test('legacy Rift history migration removes playback secrets', () async {
    final storage = _Memory();
    final history = ProviderLocalHistory(storage, animeRiftProviderId);
    storage.values[history.storageKey] = jsonEncode({
      'history': {
        'legacy': {
          'title': 'Rift',
          'url': 'https://www.anime-rift.com/anime/42?token=catalog-secret',
          'posterUrl': 'https://images.example/poster.jpg?token=poster-secret',
          'bannerUrl':
              'https://images.example/banner.jpg?signature=banner-secret',
          'provider': animeRiftProviderId,
          'position': 10,
          'duration': 100,
          'lastEpisodeUrl': 'https://cdn.example/episode-7.m3u8?token=episode-secret#fragment-secret',
          'lastStreamUrl': 'https://cdn.invalid/video?token=stream-secret',
          'episodePosterUrl':
              'https://images.example/episode.jpg?token=episode-poster-secret',
          'headers': {'Authorization': 'Bearer header-secret'},
          'streams': [
            {'url': 'https://cdn.invalid/hidden?token=nested-secret'},
          ],
          'timestamp': 100,
        },
      },
      'continue': <String, dynamic>{},
      'positions': <String, dynamic>{},
      'watched': <String, dynamic>{},
    });

    await history.recordOpened(
      MultimediaItem(
        title: 'Rift',
        url: 'https://anime-rift.com/anime/42',
        posterUrl: '',
      ),
      episodeUrl: 'https://anime-rift.com/episode/7',
    );

    final persisted = storage.values[history.storageKey]!;
    expect(persisted, isNot(contains('catalog-secret')));
    expect(persisted, isNot(contains('episode-secret')));
    expect(persisted, isNot(contains('stream-secret')));
    expect(persisted, isNot(contains('header-secret')));
    expect(persisted, isNot(contains('nested-secret')));
    expect(persisted, isNot(contains('poster-secret')));
    expect(persisted, isNot(contains('banner-secret')));
    expect(persisted, isNot(contains('fragment-secret')));
    expect(persisted, isNot(contains('episode-poster-secret')));
  });

  test('Rift history drops signed external resource URLs but keeps stable episode identity', () async {
    final storage = _Memory();
    final history = ProviderLocalHistory(storage, animeRiftProviderId);
    final item = MultimediaItem(
      title: 'Rift',
      url: 'https://anime-rift.com/anime/42',
      posterUrl: 'https://images.example/poster.jpg?token=poster-secret',
      bannerUrl: 'https://images.example/banner.jpg',
      provider: animeRiftProviderId,
      contentType: MultimediaContentType.anime,
    );
    const signedEpisode =
        'https://cdn.example/episode-7.m3u8?token=episode-secret#fragment-secret';

    await history.saveProgress(
      item,
      42,
      100,
      episodeUrl: signedEpisode,
      episodePosterUrl:
          'https://images.example/episode.jpg?token=episode-poster-secret',
    );

    final persisted = storage.values[history.storageKey]!;
    expect(persisted, isNot(contains('poster-secret')));
    expect(persisted, isNot(contains('episode-secret')));
    expect(persisted, isNot(contains('fragment-secret')));
    expect(persisted, isNot(contains('episode-poster-secret')));

    final restored = ProviderLocalHistory(storage, animeRiftProviderId);
    final row = restored.continueWatching().single;
    expect(row.item.posterUrl, isEmpty);
    expect(row.item.bannerUrl, 'https://images.example/banner.jpg');
    expect(row.lastEpisodeUrl ?? '', isEmpty);
    expect(row.episodePosterUrl, isNull);
    expect(
      restored.position(
        item.url,
        'https://cdn.example/episode-7.m3u8?token=refreshed-secret',
      ),
      42,
    );

    await restored.recordOpened(item, episodeUrl: 'episode-7');
    expect(restored.history().single.lastEpisodeUrl, 'episode-7');
  });

  test('Rift alias progress collision keeps the newest progress', () async {
    final storage = _Memory();
    final history = ProviderLocalHistory(storage, animeRiftProviderId);
    const canonical = 'https://anime-rift.com/anime/42';
    const alias = 'https://www.anime-rift.com/anime/42';
    const episode = 'https://anime-rift.com/episode/7';
    storage.values[history.storageKey] = jsonEncode({
      'history': {
        'newer': {
          'title': 'Rift',
          'url': canonical,
          'provider': animeRiftProviderId,
          'position': 80,
          'duration': 100,
          'lastEpisodeUrl': episode,
          'timestamp': 200,
        },
        'older': {
          'title': 'Rift',
          'url': alias,
          'provider': animeRiftProviderId,
          'position': 20,
          'duration': 100,
          'lastEpisodeUrl': episode,
          'timestamp': 100,
        },
      },
      'continue': <String, dynamic>{},
      'positions': {
        jsonEncode([canonical, episode]): {'position': 80, 'duration': 100},
        jsonEncode([alias, episode]): {'position': 20, 'duration': 100},
      },
      'watched': <String, dynamic>{},
    });

    expect(history.position(canonical, episode), 80);
    expect(history.duration(canonical, episode), 100);
  });

  test(
    'Rift watched and progress identities survive legacy signed episode URLs',
    () async {
      final storage = _Memory();
      final history = ProviderLocalHistory(storage, animeRiftProviderId);
      const aliasMain = 'https://www.anime-rift.com/anime/42';
      const canonicalMain = 'https://anime-rift.com/anime/42';
      const legacyEpisode =
          'https://www.anime-rift.com/episode/7?token=old-secret';
      const freshEpisode =
          'https://anime-rift.com/episode/7?token=fresh-secret';
      final legacyWatchedKey = jsonEncode([
        aliasMain,
        ['url', legacyEpisode, DubStatus.subbed.name],
      ]);
      storage.values[history.storageKey] = jsonEncode({
        'history': <String, dynamic>{},
        'continue': <String, dynamic>{},
        'positions': {
          jsonEncode([aliasMain, legacyEpisode]): {
            'position': 45,
            'duration': 100,
          },
        },
        'watched': {legacyWatchedKey: true},
      });
      final episode = Episode(
        name: '7',
        url: freshEpisode,
        dubStatus: DubStatus.subbed,
      );

      expect(history.position(canonicalMain, freshEpisode), 45);
      expect(history.isWatched(canonicalMain, episode), isTrue);

      await history.setWatched(canonicalMain, episode, true);
      final persisted = storage.values[history.storageKey]!;
      expect(persisted, isNot(contains('old-secret')));
      expect(persisted, isNot(contains('fresh-secret')));
    },
  );
}

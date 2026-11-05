import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Memory extends StorageService {
  final values = <String, String>{};
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  List<Map<String, dynamic>> getWatchHistory() => [
    {
      'title': 'Native',
      'url': 'same',
      'provider': 'com.fares669.animewitcher.native',
    },
  ];
  @override
  List<Map<String, dynamic>> getContinueWatching() => [];
}

void main() {
  test(
    'Rift episode watch toggles queue exact episode number and desired state',
    () async {
      final storage = _Memory();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      final sent = <String>[];
      final watched = EpisodeWatchRepository(
        storage,
        HistoryRepository(storage, account),
        account,
        () {},
        () async {},
        (url, number, value) async => sent.add('$url:$number:$value'),
      );
      final item = MultimediaItem(
        title: 'Rift',
        url: 'https://anime-rift.com/anime/watch-id',
        posterUrl: '',
        provider: animeRiftProviderId,
      );
      final episode = Episode(name: 'Episode 4', url: 'episode-4', episode: 4);
      await watched.setWatchedFor(item, episode, true);
      await watched.setWatchedFor(item, episode, false);
      expect(sent, ['${item.url}:4:true', '${item.url}:4:false']);
      expect(watched.isWatchedFor(item, episode), isFalse);
    },
  );

  test(
    'Rift watched episodes remain local and ignore native account state',
    () async {
      final storage = _Memory();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      final history = HistoryRepository(storage, account);
      var changes = 0;
      final watched = EpisodeWatchRepository(
        storage,
        history,
        account,
        () => changes++,
      );
      final item = MultimediaItem(
        title: 'Rift',
        url: 'same',
        posterUrl: '',
        provider: animeRiftProviderId,
      );
      final episode = Episode(name: '1', url: 'episode');
      await watched.setWatchedFor(item, episode, true);
      expect(watched.isWatchedFor(item, episode), isTrue);
      expect(watched.getExplicitStateFor(item, episode), isTrue);
      expect(changes, 1);
      await watched.setWatchedFor(item, episode, false);
      expect(watched.isWatchedFor(item, episode), isFalse);
    },
  );

  test(
    'history repository routes Rift records only to local storage',
    () async {
      final storage = _Memory();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      final history = HistoryRepository(storage, account);
      final item = MultimediaItem(
        title: 'Rift',
        url: 'same',
        posterUrl: '',
        provider: animeRiftProviderId,
        contentType: MultimediaContentType.anime,
      );
      await history.recordOpened(item, lastEpisodeUrl: 'episode');
      await history.saveContinueWatchingProgress(
        item,
        25,
        100,
        lastEpisodeUrl: 'episode',
      );
      expect(history.getWatchHistory().single.item.title, 'Native');
      expect(historyForItem(history, item).single.item.title, 'Rift');
      expect(
        history.getWatchHistoryFor(animeRiftProviderId).single.item.title,
        'Rift',
      );
      expect(
        history.getContinueWatchingFor(animeRiftProviderId).single.position,
        25,
      );
      expect(history.positionForItem(item, episodeUrl: 'episode'), 25);
      await history.clearContinueWatchingFor(animeRiftProviderId);
      expect(history.getContinueWatchingFor(animeRiftProviderId), isEmpty);
      expect(history.getWatchHistory().single.item.title, 'Native');
    },
  );

  test(
    'Rift history survives repository recreation with source identity',
    () async {
      final storage = _Memory();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      final history = HistoryRepository(storage, account);
      final item = MultimediaItem(
        title: 'Rift persisted',
        url: 'same',
        posterUrl: 'poster',
        provider: animeRiftProviderId,
        contentType: MultimediaContentType.anime,
      );
      await history.recordOpened(item, lastEpisodeUrl: 'episode/7');
      await history.saveContinueWatchingProgress(
        item,
        70,
        100,
        lastEpisodeUrl: 'episode/7',
      );

      final restarted = HistoryRepository(storage, account);
      final restoredHistory = restarted.getWatchHistoryFor(animeRiftProviderId);
      final restoredContinue = restarted.getContinueWatchingFor(
        animeRiftProviderId,
      );

      expect(restoredHistory, hasLength(1));
      expect(restoredHistory.single.item.provider, animeRiftProviderId);
      expect(restoredHistory.single.item.url, item.url);
      expect(restoredHistory.single.lastEpisodeUrl, 'episode/7');
      expect(restoredContinue, hasLength(1));
      expect(restoredContinue.single.item.provider, animeRiftProviderId);
      expect(restoredContinue.single.position, 70);
      expect(restarted.getWatchHistory().single.item.title, 'Native');
    },
  );

  test(
    'completed Rift movie clears resume position but keeps history',
    () async {
      final storage = _Memory();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      final history = HistoryRepository(storage, account);
      final item = MultimediaItem(
        title: 'Rift movie',
        url: 'rift://movie/42',
        posterUrl: '',
        provider: animeRiftProviderId,
        contentType: MultimediaContentType.movie,
      );
      await history.saveContinueWatchingProgress(item, 50, 100);
      expect(history.positionForItem(item), 50);

      await history.completeItemFor(item);

      expect(history.positionForItem(item), 0);
      expect(history.durationForItem(item), 0);
      expect(history.getContinueWatchingFor(animeRiftProviderId), isEmpty);
      final record = history.getWatchHistoryFor(animeRiftProviderId).single;
      expect(record.item.url, item.url);
      expect(record.position, 0);
      expect(record.duration, 0);
    },
  );

  test('Rift history never persists signed stream URLs', () async {
    final storage = _Memory();
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: SecureTokenStorage(storage),
    );
    final history = HistoryRepository(storage, account);
    final item = MultimediaItem(
      title: 'Rift',
      url: 'https://anime-rift.com/anime/42',
      posterUrl: '',
      provider: animeRiftProviderId,
      contentType: MultimediaContentType.movie,
    );
    const signed =
        'https://video.test/movie.mp4?token=secret&signature=private';

    await history.saveContinueWatchingProgress(
      item,
      50,
      100,
      lastStreamUrl: signed,
    );

    expect(
      history.getContinueWatchingFor(animeRiftProviderId).single.lastStreamUrl,
      isNull,
    );
    expect(storage.values.values.join('\n'), isNot(contains('secret')));
    expect(storage.values.values.join('\n'), isNot(contains('signature')));
  });

  test('Rift www and canonical catalog URLs share playback identity', () async {
    final storage = _Memory();
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: SecureTokenStorage(storage),
    );
    final history = HistoryRepository(storage, account);
    final wwwItem = MultimediaItem(
      title: 'Rift',
      url: 'https://www.anime-rift.com/anime/42',
      posterUrl: '',
      provider: animeRiftProviderId,
    );
    final canonicalItem = wwwItem.copyWith(
      url: 'https://anime-rift.com/anime/42',
    );

    await history.saveContinueWatchingProgress(
      wwwItem,
      33,
      100,
      lastEpisodeUrl: 'episode-1',
    );

    expect(history.positionForItem(canonicalItem, episodeUrl: 'episode-1'), 33);
    expect(
      history.getWatchHistoryFor(animeRiftProviderId).single.item.url,
      canonicalItem.url,
    );
  });

  test(
    'Rift playback position disappears after both visible records are removed',
    () async {
      final storage = _Memory();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      final history = HistoryRepository(storage, account);
      final item = MultimediaItem(
        title: 'Rift',
        url: 'https://anime-rift.com/anime/42',
        posterUrl: '',
        provider: animeRiftProviderId,
      );

      await history.saveContinueWatchingProgress(
        item,
        55,
        100,
        lastEpisodeUrl: 'episode-1',
      );
      await history.removeContinueWatchingFor(item.url, animeRiftProviderId);
      expect(history.positionForItem(item, episodeUrl: 'episode-1'), 55);

      await history.removeHistoryFor(item.url, animeRiftProviderId);
      expect(history.positionForItem(item, episodeUrl: 'episode-1'), 0);
      expect(history.durationForItem(item, episodeUrl: 'episode-1'), 0);
    },
  );
}

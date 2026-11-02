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
}

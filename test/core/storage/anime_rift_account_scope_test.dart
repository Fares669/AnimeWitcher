import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/storage/provider_local_history.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Memory extends StorageService {
  final values = <String, String>{};

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
  tearDown(AnimeRiftLocalAccountScope.reset);

  test(
    'switching Rift accounts keeps libraries and guest data separate',
    () async {
      final storage = _Memory();
      final item = MultimediaItem(
        title: 'Anime',
        url: 'https://anime-rift.com/anime/12',
        posterUrl: '',
        provider: animeRiftProviderId,
      );

      final guest = ProviderLocalLibrary(storage, animeRiftProviderId);
      await guest.setFavorite(item, true);
      final guestKey = guest.storageKey;

      AnimeRiftLocalAccountScope.activate('rift-user-A');
      final alice = ProviderLocalLibrary(storage, animeRiftProviderId);
      expect(alice.storageKey, isNot(guestKey));
      expect(alice.isFavorite(item.url), isFalse);
      final pendingAlice = alice.setFavorite(item, true);
      // In-flight writes must stay in the partition they started in.
      AnimeRiftLocalAccountScope.activate('rift-user-B');
      final bob = ProviderLocalLibrary(storage, animeRiftProviderId);
      expect(bob.storageKey, isNot(alice.storageKey));
      await pendingAlice;
      await bob.setFavorite(item, false);
      expect(bob.isFavorite(item.url), isFalse);

      AnimeRiftLocalAccountScope.activate('rift-user-A');
      final aliceRestored = ProviderLocalLibrary(storage, animeRiftProviderId);
      expect(aliceRestored.storageKey, alice.storageKey);
      expect(aliceRestored.isFavorite(item.url), isTrue);
      AnimeRiftLocalAccountScope.reset();
      expect(
        ProviderLocalLibrary(storage, animeRiftProviderId).isFavorite(item.url),
        isTrue,
      );
      expect(storage.values.containsKey(guestKey), isTrue);
    },
  );

  test(
    'history and watched progress are partitioned by Rift account',
    () async {
      final storage = _Memory();
      final item = MultimediaItem(
        title: 'Anime',
        url: 'https://anime-rift.com/anime/12',
        posterUrl: '',
        provider: animeRiftProviderId,
      );
      final episode = Episode(
        name: '1',
        url: 'https://anime-rift.com/episode/1',
      );
      AnimeRiftLocalAccountScope.activate('rift-user-A');
      final alice = ProviderLocalHistory(storage, animeRiftProviderId);
      await alice.saveProgress(item, 45, 100, episodeUrl: episode.url);
      await alice.setWatched(item.url, episode, true);

      AnimeRiftLocalAccountScope.activate('rift-user-B');
      final bob = ProviderLocalHistory(storage, animeRiftProviderId);
      expect(bob.storageKey, isNot(alice.storageKey));
      expect(bob.position(item.url, episode.url), 0);
      expect(bob.isWatched(item.url, episode), isNull);
      await bob.saveProgress(item, 10, 100, episodeUrl: episode.url);

      AnimeRiftLocalAccountScope.activate('rift-user-A');
      final restored = ProviderLocalHistory(storage, animeRiftProviderId);
      expect(restored.position(item.url, episode.url), 45);
      expect(restored.isWatched(item.url, episode), isTrue);

      AnimeRiftLocalAccountScope.reset();
      expect(
        ProviderLocalHistory(
          storage,
          animeRiftProviderId,
        ).position(item.url, episode.url),
        0,
      );
    },
  );

  test('other providers keep their existing storage identities', () {
    final storage = _Memory();
    final old = ProviderLocalLibrary(storage, 'native-provider').storageKey;
    AnimeRiftLocalAccountScope.activate('rift-user-A');
    expect(ProviderLocalLibrary(storage, 'native-provider').storageKey, old);
  });
}

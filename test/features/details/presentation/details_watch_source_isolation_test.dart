import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _episode = Episode(name: 'ep', url: 'episode', season: 1, episode: 1);
final _item = MultimediaItem(
  title: 'Witcher',
  url: 'same',
  posterUrl: '',
  provider: 'com.fares669.animewitcher.native',
);

class _Details extends DetailsController {
  @override
  DetailsState build(String itemUrl) => DetailsState(
    item: _item,
    seasonMap: {
      1: [_episode],
    },
    selectedEpisodeKeys: {episodeSelectionKey(_episode)},
  );
}

class _Watch extends EpisodeWatchRepository {
  _Watch(StorageService storage, AnimeWitcherAccountService account)
    : super(storage, HistoryRepository(storage, account), account, () {});
  @override
  Future<void> setManyWatched(
    String mainUrl,
    Iterable<Episode> episodes,
    bool watched,
  ) async {}
}

class _Continue extends ContinueWatchingNotifier {
  MultimediaItem? removed;
  int unqualifiedRemovals = 0;
  @override
  List<HistoryItem> build() => [];
  @override
  Future<void> remove(String url) async {
    unqualifiedRemovals++;
  }

  @override
  Future<void> removeForItem(MultimediaItem item) async {
    removed = item;
  }
}

void main() {
  test(
    'marking a native item watched routes continue removal by item identity',
    () async {
      final storage = StorageService();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      final container = ProviderContainer(
        overrides: [
          detailsControllerProvider(_item.url).overrideWith(_Details.new),
          episodeWatchRepositoryProvider.overrideWithValue(
            _Watch(storage, account),
          ),
          continueWatchingProvider.overrideWith(_Continue.new),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(detailsControllerProvider(_item.url).notifier)
          .setSelectedEpisodesWatched(_item.url, true);
      final history =
          container.read(continueWatchingProvider.notifier) as _Continue;
      expect(history.removed, same(_item));
      expect(history.unqualifiedRemovals, 0);
    },
  );
}

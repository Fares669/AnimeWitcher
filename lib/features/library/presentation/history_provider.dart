import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/anime_rift_auto_sync.dart';
import 'package:animewitcher/core/utils/anime_rift_identity.dart';

import '../../../../core/storage/history_repository.dart';
import '../../../../core/domain/entity/multimedia_item.dart';

export '../../../../core/storage/history_repository.dart' show HistoryItem;

part 'history_provider.g.dart';

@Riverpod(keepAlive: true)
class WatchHistory extends _$WatchHistory {
  @override
  List<HistoryItem> build() {
    ref.watch(accountDataRevisionProvider);
    final repository = ref.watch(historyRepositoryProvider);
    final id = ref.watch(activeProviderProvider)?.packageName;
    return id == animeRiftProviderId
        ? repository.getWatchHistoryFor(id)
        : repository.getWatchHistory();
  }

  void refresh() {
    final repository = ref.read(historyRepositoryProvider);
    final id = ref.read(activeProviderProvider)?.packageName;
    state = id == animeRiftProviderId
        ? repository.getWatchHistoryFor(id)
        : repository.getWatchHistory();
  }

  Future<void> refreshFromServer() async {
    final repository = ref.read(historyRepositoryProvider);
    if (ref.read(activeProviderProvider)?.packageName == animeRiftProviderId) {
      await ref.read(riftAutoSyncProvider).refresh();
    } else {
      await repository.syncRecentWatched();
    }
    refresh();
  }

  Future<void> clearAllHistory() async {
    final repository = ref.read(historyRepositoryProvider);
    final id = ref.read(activeProviderProvider)?.packageName;
    if (id == animeRiftProviderId) {
      await repository.clearHistoryFor(id);
      await ref.read(riftAutoSyncProvider).queueHistoryClear();
    } else {
      await repository.clearAllHistory();
    }
    refresh();
  }

  Future<void> removeFromHistory(String url) async {
    final repository = ref.read(historyRepositoryProvider);
    final id = ref.read(activeProviderProvider)?.packageName;
    if (id == animeRiftProviderId) {
      await repository.removeHistoryFor(url, id);
      await ref.read(riftAutoSyncProvider).queueHistory(url, false);
    } else {
      await repository.removeFromHistory(url);
    }
    refresh();
  }

  Future<void> removeForItem(MultimediaItem item) async {
    await ref
        .read(historyRepositoryProvider)
        .removeHistoryFor(item.url, item.provider);
    if (item.provider == animeRiftProviderId) {
      await ref.read(riftAutoSyncProvider).queueHistory(item.url, false);
    }
    refresh();
  }

  Future<void> updateHistoryItemTimestampAndPosition(
    HistoryItem item,
    int timestamp,
    int position,
  ) async {
    final repository = ref.read(historyRepositoryProvider);
    await repository.updateHistoryItemTimestampAndPosition(
      item,
      timestamp,
      position,
    );
    refresh();
  }

  Future<void> recordOpened(
    MultimediaItem item, {
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
  }) async {
    final repository = ref.read(historyRepositoryProvider);
    await repository.recordOpened(
      item,
      lastEpisodeUrl: lastEpisodeUrl,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      episodeServerName: episodeServerName,
      episodeServerNumber: episodeServerNumber,
      episodePosterUrl: episodePosterUrl,
    );
    if (item.provider == animeRiftProviderId) {
      await ref.read(riftAutoSyncProvider).queueHistory(item.url, true);
    }
    refresh();
  }
}

class ContinueWatchingNotifier extends Notifier<List<HistoryItem>> {
  @override
  List<HistoryItem> build() {
    ref.watch(accountDataRevisionProvider);
    final repository = ref.watch(historyRepositoryProvider);
    final id = ref.watch(activeProviderProvider)?.packageName;
    return id == animeRiftProviderId
        ? repository.getContinueWatchingFor(id)
        : repository.getContinueWatching();
  }

  void refresh() {
    final repository = ref.read(historyRepositoryProvider);
    final id = ref.read(activeProviderProvider)?.packageName;
    state = id == animeRiftProviderId
        ? repository.getContinueWatchingFor(id)
        : repository.getContinueWatching();
  }

  Future<void> refreshFromServer() async {
    if (ref.read(activeProviderProvider)?.packageName == animeRiftProviderId) {
      await ref.read(riftAutoSyncProvider).refresh();
    } else {
      await ref.read(historyRepositoryProvider).syncContinueWatching();
    }
    refresh();
  }

  Future<void> clearAll() =>
      clearAllFor(ref.read(activeProviderProvider)?.packageName);

  Future<void> clearAllFor(String? providerId) async {
    await ref
        .read(historyRepositoryProvider)
        .clearContinueWatchingFor(providerId);
    if (providerId == animeRiftProviderId) {
      await ref.read(riftAutoSyncProvider).queueHistoryClear();
    }
    refresh();
  }

  Future<void> remove(String url) async {
    final repository = ref.read(historyRepositoryProvider);
    final id = ref.read(activeProviderProvider)?.packageName;
    if (id == animeRiftProviderId) {
      await repository.removeContinueWatchingFor(url, id);
      await ref.read(riftAutoSyncProvider).queueHistory(url, false);
    } else {
      await repository.removeContinueWatching(url);
    }
    refresh();
  }

  Future<void> removeForItem(MultimediaItem item) async {
    final repository = ref.read(historyRepositoryProvider);
    if (item.provider == animeRiftProviderId) {
      await repository.removeContinueWatchingFor(item.url, item.provider);
      await ref.read(riftAutoSyncProvider).queueHistory(item.url, false);
    } else {
      await repository.removeContinueWatching(item.url);
    }
    refresh();
  }

  Future<void> completeForItem(MultimediaItem item) async {
    await ref.read(historyRepositoryProvider).completeItemFor(item);
    refresh();
  }

  Future<void> saveProgress(
    MultimediaItem item,
    int position,
    int duration, {
    String? lastStreamUrl,
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
  }) async {
    await ref
        .read(historyRepositoryProvider)
        .saveContinueWatchingProgress(
          item,
          position,
          duration,
          lastStreamUrl: lastStreamUrl,
          lastEpisodeUrl: lastEpisodeUrl,
          season: season,
          episode: episode,
          episodeTitle: episodeTitle,
          episodeServerName: episodeServerName,
          episodeServerNumber: episodeServerNumber,
          episodePosterUrl: episodePosterUrl,
        );
    if (item.provider == animeRiftProviderId) {
      await ref
          .read(riftAutoSyncProvider)
          .queuePlayback(
            item.url,
            episodeIdentity: animeRiftEpisodeIdForSync(lastEpisodeUrl),
            position: position,
            duration: duration,
            season: season,
            episode: episode,
          );
    }
    refresh();
  }
}

final continueWatchingProvider =
    NotifierProvider<ContinueWatchingNotifier, List<HistoryItem>>(
      ContinueWatchingNotifier.new,
    );

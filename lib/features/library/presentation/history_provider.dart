import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:animewitcher/core/account/account_providers.dart';

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
    return repository.getWatchHistory();
  }

  void refresh() {
    final repository = ref.read(historyRepositoryProvider);
    state = repository.getWatchHistory();
  }

  Future<void> refreshFromServer() async {
    final repository = ref.read(historyRepositoryProvider);
    await repository.syncRecentWatched();
    refresh();
  }

  Future<void> clearAllHistory() async {
    final repository = ref.read(historyRepositoryProvider);
    await repository.clearAllHistory();
    refresh();
  }

  Future<void> removeFromHistory(String url) async {
    final repository = ref.read(historyRepositoryProvider);
    await repository.removeFromHistory(url);
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
    refresh();
  }
}

class ContinueWatchingNotifier extends Notifier<List<HistoryItem>> {
  @override
  List<HistoryItem> build() {
    ref.watch(accountDataRevisionProvider);
    final repository = ref.watch(historyRepositoryProvider);
    return repository.getContinueWatching();
  }

  void refresh() {
    state = ref.read(historyRepositoryProvider).getContinueWatching();
  }

  Future<void> refreshFromServer() async {
    await ref.read(historyRepositoryProvider).syncContinueWatching();
    refresh();
  }

  Future<void> clearAll() async {
    await ref.read(historyRepositoryProvider).clearContinueWatching();
    refresh();
  }

  Future<void> remove(String url) async {
    await ref.read(historyRepositoryProvider).removeContinueWatching(url);
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
    refresh();
  }
}

final continueWatchingProvider =
    NotifierProvider<ContinueWatchingNotifier, List<HistoryItem>>(
      ContinueWatchingNotifier.new,
    );

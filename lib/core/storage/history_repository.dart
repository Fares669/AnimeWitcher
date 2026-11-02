import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../account/account_providers.dart';
import '../account/animewitcher_account_service.dart';
import '../domain/entity/multimedia_item.dart';
import 'storage_service.dart';
import 'provider_local_history.dart';
import 'provider_local_library.dart';

part 'history_repository.g.dart';

class HistoryItem {
  final MultimediaItem item;
  final int position;
  final int duration;
  final String? lastStreamUrl;
  final String? lastEpisodeUrl;
  final int? season;
  final int? episode;
  final String? episodeTitle;
  final String? episodeServerName;
  final String? episodeServerNumber;
  final String? episodePosterUrl;
  final int timestamp;

  HistoryItem({
    required this.item,
    required this.position,
    required this.duration,
    this.lastStreamUrl,
    this.lastEpisodeUrl,
    this.season,
    this.episode,
    this.episodeTitle,
    this.episodeServerName,
    this.episodeServerNumber,
    this.episodePosterUrl,
    required this.timestamp,
    this.progressPercentage,
  });

  final int? progressPercentage;

  double get progress {
    final saved = progressPercentage;
    if (saved != null) return saved.clamp(0, 100) / 100;
    return duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0;
  }

  factory HistoryItem.fromMap(Map<String, dynamic> map) {
    return HistoryItem(
      item: MultimediaItem(
        title: (map['title'] as String?) ?? '',
        url: (map['url'] as String?) ?? '',
        posterUrl: (map['posterUrl'] as String?) ?? '',
        bannerUrl: map['bannerUrl'] as String?,
        description: map['description'] as String?,
        contentType: MultimediaItem.parseContentType(
          (map['type'] as String?) ??
              (map['contentType'] as String?) ??
              'movie',
        ),
        catalogType: map['catalogType'] as String?,
        year: (map['year'] as num?)?.toInt(),
        isDubbed: map['isDubbed'] == true,
        provider: map['provider'] as String?,
        tmdbId: map['tmdbId'] as int?,
        imdbId: map['imdbId'] as String?,
      ),
      position: (map['position'] as int?) ?? 0,
      duration: (map['duration'] as int?) ?? 0,
      progressPercentage: (map['progress'] as num?)?.round(),
      lastStreamUrl: map['lastStreamUrl'] as String?,
      lastEpisodeUrl: map['lastEpisodeUrl'] as String?,
      season: map['season'] as int?,
      episode: map['episode'] as int?,
      episodeTitle: map['episodeTitle'] as String?,
      episodeServerName: map['episodeServerName'] as String?,
      episodeServerNumber: map['episodeServerNumber'] as String?,
      episodePosterUrl: map['episodePosterUrl'] as String?,
      timestamp: (map['timestamp'] as int?) ?? 0,
    );
  }
}

List<HistoryItem> historyForItem(HistoryRepository repository, MultimediaItem item) =>
    item.provider == animeRiftProviderId
        ? repository.getWatchHistoryFor(animeRiftProviderId)
        : repository.getWatchHistory();

int historyPositionForItem(
  HistoryRepository repository,
  MultimediaItem item, {
  String? episodeUrl,
  int? season,
  int? episode,
}) {
  if (item.provider == animeRiftProviderId) {
    return repository.positionForItem(
      item,
      episodeUrl: episodeUrl,
      season: season,
      episode: episode,
    );
  }
  return episodeUrl == null
      ? repository.getPosition(item.url)
      : repository.getEpisodePosition(
          episodeUrl,
          mainUrl: item.url,
          season: season,
          episode: episode,
        );
}

int historyDurationForItem(
  HistoryRepository repository,
  MultimediaItem item, {
  String? episodeUrl,
  int? season,
  int? episode,
}) {
  if (item.provider == animeRiftProviderId) {
    return repository.durationForItem(
      item,
      episodeUrl: episodeUrl,
      season: season,
      episode: episode,
    );
  }
  return episodeUrl == null
      ? repository.getDuration(item.url)
      : repository.getEpisodeDuration(
          episodeUrl,
          mainUrl: item.url,
          season: season,
          episode: episode,
        );
}

@Riverpod(keepAlive: true)
HistoryRepository historyRepository(Ref ref) {
  return HistoryRepository(
    ref.watch(storageServiceProvider),
    ref.watch(animeWitcherAccountServiceProvider),
  );
}

class HistoryRepository {
  final StorageService _storageService;
  final AnimeWitcherAccountService _accountService;

  HistoryRepository(this._storageService, this._accountService);

  ProviderLocalHistory _local() =>
      ProviderLocalHistory(_storageService, animeRiftProviderId);

  List<HistoryItem> getWatchHistoryFor(String? providerId) =>
      providerId == animeRiftProviderId
      ? _local().history()
      : getWatchHistory();
  List<HistoryItem> getContinueWatchingFor(String? providerId) =>
      providerId == animeRiftProviderId
      ? _local().continueWatching()
      : getContinueWatching();
  Future<void> clearContinueWatchingFor(String? providerId) =>
      providerId == animeRiftProviderId
      ? _local().clearContinueWatching()
      : clearContinueWatching();
  Future<void> removeContinueWatchingFor(String url, String? providerId) =>
      providerId == animeRiftProviderId
      ? _local().removeContinueWatching(url)
      : removeContinueWatching(url);
  Future<void> clearHistoryFor(String? providerId) =>
      providerId == animeRiftProviderId
      ? _local().clearHistory()
      : clearAllHistory();
  Future<void> removeHistoryFor(String url, String? providerId) =>
      providerId == animeRiftProviderId
      ? _local().removeHistory(url)
      : removeFromHistory(url);

  int positionForItem(
    MultimediaItem item, {
    String? episodeUrl,
    int? season,
    int? episode,
  }) {
    if (item.provider == animeRiftProviderId) {
      return _local().position(item.url, episodeUrl);
    }
    return episodeUrl == null
        ? getPosition(item.url)
        : getEpisodePosition(
            episodeUrl,
            mainUrl: item.url,
            season: season,
            episode: episode,
          );
  }

  int durationForItem(
    MultimediaItem item, {
    String? episodeUrl,
    int? season,
    int? episode,
  }) {
    if (item.provider == animeRiftProviderId) {
      return _local().duration(item.url, episodeUrl);
    }
    return episodeUrl == null
        ? getDuration(item.url)
        : getEpisodeDuration(
            episodeUrl,
            mainUrl: item.url,
            season: season,
            episode: episode,
          );
  }

  Future<void> removeFromHistory(String url) async {
    await _storageService.removeFromHistory(url);
    _syncInBackground(
      _accountService.removeLastWatched(url),
      'remove recently-watched item',
    );
  }

  Future<void> updateHistoryItemTimestampAndPosition(
    HistoryItem item,
    int timestamp,
    int position,
  ) async {
    if (item.item.provider == animeRiftProviderId) {
      await _local().updateHistory(item, timestamp, position);
      return;
    }
    await _storageService.updateHistoryItemTimestampAndPosition(
      item.item.url,
      item.lastEpisodeUrl,
      timestamp,
      position,
    );
    _syncInBackground(
      _accountService.recordLastWatched(item: item.item),
      'update recently-watched timestamp',
    );
  }

  Future<void> clearAllHistory() async {
    final urls = _storageService
        .getWatchHistory()
        .map((item) => (item['url'] ?? '').toString())
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
    await _storageService.clearAllHistory();
    for (final url in urls) {
      _syncInBackground(
        _accountService.removeLastWatched(url),
        'clear recently-watched item',
      );
    }
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
    if (item.provider == animeRiftProviderId) {
      await _local().recordOpened(
        item,
        episodeUrl: lastEpisodeUrl,
        season: season,
        episode: episode,
        episodeTitle: episodeTitle,
        episodeServerName: episodeServerName,
        episodeServerNumber: episodeServerNumber,
        episodePosterUrl: episodePosterUrl,
      );
      return;
    }
    await _storageService.recordHistoryOpen(
      item,
      lastEpisodeUrl: lastEpisodeUrl,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      episodeServerName: episodeServerName,
      episodeServerNumber: episodeServerNumber,
      episodePosterUrl: episodePosterUrl,
    );
    _syncInBackground(
      _accountService.recordLastWatched(item: item),
      'record recently-watched item',
    );
  }

  Future<void> saveContinueWatchingProgress(
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
    if (item.provider == animeRiftProviderId) {
      await _local().saveProgress(
        item,
        position,
        duration,
        episodeUrl: lastEpisodeUrl,
        season: season,
        episode: episode,
        episodeTitle: episodeTitle,
        episodeServerName: episodeServerName,
        episodeServerNumber: episodeServerNumber,
        episodePosterUrl: episodePosterUrl,
        lastStreamUrl: lastStreamUrl,
      );
      return;
    }
    await _storageService.saveContinueWatchingProgress(
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
    _syncInBackground(
      _accountService.saveContinueWatchingProgress(
        item: item,
        position: position,
        duration: duration,
        episodeUrl: lastEpisodeUrl,
        episodeNumber: episode,
        episodeTitle: episodeTitle,
        episodeServerName: episodeServerName,
        episodeServerNumber: episodeServerNumber,
        episodePosterUrl: episodePosterUrl,
      ),
      'save continue-watching progress',
    );
  }

  Future<void> removeContinueWatching(String url) async {
    await _storageService.removeFromContinueWatching(url);
    _syncInBackground(
      _accountService.removeContinueWatching(url),
      'remove continue-watching item',
    );
  }

  Future<void> clearContinueWatching() async {
    final urls = _storageService
        .getContinueWatching()
        .map((item) => (item['url'] ?? '').toString())
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
    await _storageService.clearAllContinueWatching();
    for (final url in urls) {
      _syncInBackground(
        _accountService.removeContinueWatching(url),
        'clear continue-watching item',
      );
    }
  }

  Future<void> syncContinueWatching() async {
    await _accountService.syncContinueWatching();
  }

  List<HistoryItem> getContinueWatching() {
    return _storageService
        .getContinueWatching()
        .map(HistoryItem.fromMap)
        .toList(growable: false);
  }

  Future<void> syncRecentWatched() async {
    await _accountService.syncRecentWatched();
  }

  List<HistoryItem> getWatchHistory() {
    final rawItems = _storageService.getWatchHistory();
    return rawItems.map((map) => HistoryItem.fromMap(map)).toList();
  }

  int getPosition(String url) {
    return _storageService.getPosition(url);
  }

  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) {
    return _storageService.getEpisodePosition(
      url,
      mainUrl: mainUrl,
      season: season,
      episode: episode,
    );
  }

  int getDuration(String url) {
    return _storageService.getDuration(url);
  }

  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) {
    return _storageService.getEpisodeDuration(
      url,
      mainUrl: mainUrl,
      season: season,
      episode: episode,
    );
  }

  String? getLastStreamUrl(String url) {
    return _storageService.getLastStreamUrl(url);
  }

  String? getLastEpisodeUrl(String url) {
    return _storageService.getLastEpisodeUrl(url);
  }

  void _syncInBackground(Future<void> operation, String label) {
    unawaited(
      operation.catchError((Object error) {
        if (kDebugMode) {
          debugPrint('[AnimeWitcherAccount] Could not $label: $error');
        }
      }),
    );
  }
}

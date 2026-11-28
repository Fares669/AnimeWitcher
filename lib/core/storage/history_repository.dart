import 'dart:collection';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../account/account_providers.dart';
import '../account/animewitcher_account_service.dart';
import '../domain/entity/multimedia_item.dart';
import '../services/download_v2/download_v2_identity.dart';
import 'background_sync.dart';
import 'storage_service.dart';

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

int historyPositionForItem(
  HistoryRepository repository,
  MultimediaItem item, {
  String? episodeUrl,
  int? season,
  int? episode,
}) {
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

/// A published, detached watch-history list. Its contents cannot change while
/// presentation code holds this snapshot.
final class WatchHistorySnapshot extends UnmodifiableListView<HistoryItem> {
  WatchHistorySnapshot._(List<HistoryItem> rows) : super(rows);
}

class HistoryRepository {
  final StorageService _storageService;
  final AnimeWitcherAccountService _accountService;
  List<Map<String, dynamic>>? _historySnapshot;
  List<HistoryItem> _projectedHistory = const [];
  Map<(String, String?), HistoryItem>? _historyByItem;
  Object? _continueWatchingProjectionIdentity;
  List<HistoryItem> _projectedContinueWatching = const [];

  HistoryRepository(this._storageService, this._accountService);

  List<HistoryItem> getWatchHistoryFor(String? providerId) => getWatchHistory();
  List<HistoryItem> getContinueWatchingFor(String? providerId) =>
      getContinueWatching();
  Future<void> clearContinueWatchingFor(String? providerId) =>
      clearContinueWatching();
  Future<void> removeContinueWatchingFor(String url, String? providerId) =>
      removeContinueWatching(url);
  Future<void> completeItemFor(MultimediaItem item) =>
      removeContinueWatching(item.url);
  Future<void> clearHistoryFor(String? providerId) => clearAllHistory();
  Future<void> removeHistoryFor(String url, String? providerId) =>
      removeFromHistory(url);

  int positionForItem(
    MultimediaItem item, {
    String? episodeUrl,
    int? season,
    int? episode,
  }) {
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
    reportBackgroundSyncFailure(
      _accountService.removeLastWatched(url),
      'remove recently-watched item',
    );
  }

  Future<void> updateHistoryItemTimestampAndPosition(
    HistoryItem item,
    int timestamp,
    int position,
  ) async {
    await _storageService.updateHistoryItemTimestampAndPosition(
      item.item.url,
      item.lastEpisodeUrl,
      timestamp,
      position,
    );
    reportBackgroundSyncFailure(
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
      reportBackgroundSyncFailure(
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
    reportBackgroundSyncFailure(
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
    reportBackgroundSyncFailure(
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
    reportBackgroundSyncFailure(
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
      reportBackgroundSyncFailure(
        _accountService.removeContinueWatching(url),
        'clear continue-watching item',
      );
    }
  }

  Future<void> syncContinueWatching() async {
    await _accountService.syncContinueWatching();
  }

  List<HistoryItem> getContinueWatching() {
    final rows = _storageService.getContinueWatching();
    // An account revision can concern something other than playback. Reuse
    // the projection only when storage still owns the same immutable rows.
    if (rows is! ContinueWatchingStorageSnapshot) {
      _continueWatchingProjectionIdentity = null;
      _projectedContinueWatching = const [];
      return rows.map(HistoryItem.fromMap).toList(growable: false);
    }

    final identity = rows.projectionIdentity;
    if (!identical(identity, _continueWatchingProjectionIdentity)) {
      _projectedContinueWatching = UnmodifiableListView(
        rows.map(HistoryItem.fromMap).toList(growable: false),
      );
      _continueWatchingProjectionIdentity = identity;
    }
    return _projectedContinueWatching;
  }

  Future<void> syncRecentWatched() async {
    await _accountService.syncRecentWatched();
  }

  // StorageService replaces the sorted snapshot after committing history
  // mutations, including direct cloud writes that bypass this repository. An
  // unrelated account revision or another view can reuse the same projection.
  List<HistoryItem> getWatchHistory() {
    final rows = _storageService.getWatchHistory();
    if (!identical(rows, _historySnapshot)) {
      _projectedHistory = WatchHistorySnapshot._(
        rows.map(HistoryItem.fromMap).toList(growable: false),
      );
      _historySnapshot = rows;
      _historyByItem = null;
    }
    return _projectedHistory;
  }

  HistoryItem? getWatchHistoryItem(MultimediaItem item) {
    final rows = getWatchHistory();
    final index = _historyByItem ??= () {
      final byItem = <(String, String?), HistoryItem>{};
      final scopes = <String?, String?>{};
      for (final entry in rows) {
        final provider = entry.item.provider;
        final scope = scopes.putIfAbsent(
          provider,
          () => downloadProviderScopeV2(provider),
        );
        byItem.putIfAbsent((entry.item.url, scope), () => entry);
      }
      return byItem;
    }();
    return index[(item.url, downloadProviderScopeV2(item.provider))];
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
}

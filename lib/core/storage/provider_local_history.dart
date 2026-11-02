import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/entity/multimedia_item.dart';
import 'history_repository.dart';
import 'storage_service.dart';

/// Provider-scoped local playback data, kept separate from account sync.
class ProviderLocalHistory {
  ProviderLocalHistory(this._storage, String providerId)
    : providerId = providerId.trim() {
    if (this.providerId.isEmpty) throw ArgumentError.value(providerId);
  }

  final StorageService _storage;
  final String providerId;
  static final _queues = Expando<Map<String, Future<void>>>();
  String get storageKey =>
      'provider_history_v1_${sha256.convert(utf8.encode(providerId))}';

  Map<String, dynamic> _read() {
    final raw = _storage.getString(storageKey);
    if (raw == null) {
      return {
        'history': <String, dynamic>{},
        'continue': <String, dynamic>{},
        'positions': <String, dynamic>{},
        'watched': <String, dynamic>{},
      };
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded['history'] is! Map ||
        decoded['continue'] is! Map ||
        decoded['positions'] is! Map) {
      throw const FormatException('Invalid provider history');
    }
    if (decoded['watched'] != null && decoded['watched'] is! Map) {
      throw const FormatException('Invalid provider watched states');
    }
    decoded.putIfAbsent('watched', () => <String, dynamic>{});
    return decoded;
  }

  Future<void> _write(void Function(Map<String, dynamic>) update) {
    final queues = _queues[_storage] ??= <String, Future<void>>{};
    final previous = queues[storageKey] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      final data = _read();
      update(data);
      await _storage.setString(storageKey, jsonEncode(data));
    });
    queues[storageKey] = next;
    return next;
  }

  List<HistoryItem> _items(String type) {
    final rows = (_read()[type] as Map).values.map((value) {
      if (value is! Map) throw const FormatException('Invalid history entry');
      return HistoryItem.fromMap(Map<String, dynamic>.from(value));
    }).toList();
    rows.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return rows;
  }

  List<HistoryItem> history() => _items('history');
  List<HistoryItem> continueWatching() => _items('continue');
  String _positionKey(String mainUrl, String? episodeUrl) =>
      jsonEncode([mainUrl, episodeUrl ?? '']);
  int position(String mainUrl, [String? episodeUrl]) =>
      ((_read()['positions'] as Map)[_positionKey(mainUrl, episodeUrl)]
              as Map?)?['position']
          as int? ??
      0;
  int duration(String mainUrl, [String? episodeUrl]) =>
      ((_read()['positions'] as Map)[_positionKey(mainUrl, episodeUrl)]
              as Map?)?['duration']
          as int? ??
      0;

  Map<String, dynamic> _entry(
    MultimediaItem item, {
    String? episodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
    String? lastStreamUrl,
    int position = 0,
    int duration = 0,
  }) => {
    'title': item.title,
    'url': item.url,
    'posterUrl': item.posterUrl,
    'bannerUrl': item.bannerUrl,
    'description': item.description,
    'contentType': item.contentType.name,
    'catalogType': item.catalogType,
    'year': item.year,
    'isDubbed': item.isDubbed,
    'provider': providerId,
    'tmdbId': item.tmdbId,
    'imdbId': item.imdbId,
    'position': position,
    'duration': duration,
    'lastEpisodeUrl': episodeUrl,
    'lastStreamUrl': lastStreamUrl,
    'season': season,
    'episode': episode,
    'episodeTitle': episodeTitle,
    'episodeServerName': episodeServerName,
    'episodeServerNumber': episodeServerNumber,
    'episodePosterUrl': episodePosterUrl,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  };

  Future<void> recordOpened(
    MultimediaItem item, {
    String? episodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
  }) => _write((data) {
    final p =
        (data['positions'] as Map)[_positionKey(item.url, episodeUrl)] as Map?;
    (data['history'] as Map)[item.url] = _entry(
      item,
      episodeUrl: episodeUrl,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      episodeServerName: episodeServerName,
      episodeServerNumber: episodeServerNumber,
      episodePosterUrl: episodePosterUrl,
      position: p?['position'] as int? ?? 0,
      duration: p?['duration'] as int? ?? 0,
    );
  });

  Future<void> saveProgress(
    MultimediaItem item,
    int position,
    int duration, {
    String? episodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
    String? lastStreamUrl,
  }) => _write((data) {
    final entry = _entry(
      item,
      episodeUrl: episodeUrl,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      episodeServerName: episodeServerName,
      episodeServerNumber: episodeServerNumber,
      episodePosterUrl: episodePosterUrl,
      lastStreamUrl: lastStreamUrl,
      position: position,
      duration: duration,
    );
    (data['continue'] as Map)[item.url] = entry;
    (data['history'] as Map)[item.url] = entry;
    (data['positions'] as Map)[_positionKey(item.url, episodeUrl)] = {
      'position': position,
      'duration': duration,
    };
  });

  Future<void> updateHistory(HistoryItem item, int timestamp, int position) =>
      _write((data) {
        final entry = (data['history'] as Map)[item.item.url];
        if (entry is! Map) return;
        entry['timestamp'] = timestamp;
        entry['position'] = position;
        final key = _positionKey(item.item.url, item.lastEpisodeUrl);
        final progress = (data['positions'] as Map)[key];
        if (progress is Map) progress['position'] = position;
      });

  String _watchedKey(String mainUrl, Episode episode) => jsonEncode([
    mainUrl,
    episode.url.trim().isNotEmpty
        ? ['url', episode.url.trim(), episode.dubStatus.name]
        : [
            'number',
            episode.season,
            episode.episode,
            episode.name,
            episode.dubStatus.name,
          ],
  ]);

  bool? isWatched(String mainUrl, Episode episode) =>
      (_read()['watched'] as Map)[_watchedKey(mainUrl, episode)] as bool?;

  Future<void> setWatched(String mainUrl, Episode episode, bool watched) =>
      setManyWatched(mainUrl, [episode], watched);

  Future<void> setManyWatched(
    String mainUrl,
    Iterable<Episode> episodes,
    bool watched,
  ) => _write((data) {
    for (final episode in episodes) {
      (data['watched'] as Map)[_watchedKey(mainUrl, episode)] = watched;
    }
  });

  Future<void> clearContinueWatching() =>
      _write((data) => (data['continue'] as Map).clear());
  Future<void> removeContinueWatching(String url) =>
      _write((data) => (data['continue'] as Map).remove(url));
  Future<void> clearHistory() =>
      _write((data) => (data['history'] as Map).clear());
  Future<void> removeHistory(String url) =>
      _write((data) => (data['history'] as Map).remove(url));
}

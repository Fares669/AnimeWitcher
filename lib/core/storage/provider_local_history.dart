import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/entity/multimedia_item.dart';
import '../utils/anime_rift_identity.dart';
import 'history_repository.dart';
import 'provider_local_library.dart' show animeRiftProviderId;
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
    if (providerId == animeRiftProviderId) {
      _normalizeRiftData(decoded);
    }
    return decoded;
  }

  String _mainUrl(String value) => providerId == animeRiftProviderId
      ? canonicalAnimeRiftStorageUrl(value)
      : value.trim();

  String? _episodeStorageUrl(String? value) {
    final trimmed = value?.trim() ?? '';
    if (providerId != animeRiftProviderId || trimmed.isEmpty) return trimmed;
    return safeAnimeRiftPersistedResourceUrl(trimmed);
  }

  String _episodeIdentity(String? value) {
    final trimmed = value?.trim() ?? '';
    if (providerId != animeRiftProviderId || trimmed.isEmpty) return trimmed;
    return canonicalAnimeRiftPersistenceIdentity(trimmed);
  }

  String? _riftResourceUrl(Object? value) {
    if (providerId != animeRiftProviderId) return value?.toString().trim();
    return safeAnimeRiftPersistedResourceUrl(value?.toString());
  }

  void _normalizeRiftData(Map<String, dynamic> data) {
    final progressRecency = _legacyProgressRecency(data);
    for (final type in const <String>['history', 'continue']) {
      final source = data[type] as Map;
      final normalized = <String, dynamic>{};
      for (final value in source.values) {
        if (value is! Map) continue;
        final legacy = Map<String, dynamic>.from(value);
        final url = _mainUrl((legacy['url'] ?? '').toString());
        if (url.isEmpty) continue;
        final row = _riftHistorySnapshot(legacy, url);
        final previous = normalized[url];
        if (previous is! Map ||
            (row['timestamp'] as int? ?? 0) >=
                (previous['timestamp'] as int? ?? 0)) {
          normalized[url] = row;
        }
      }
      data[type] = normalized;
    }
    final positions = data['positions'] as Map;
    final normalizedPositions = <String, dynamic>{};
    final normalizedRecency = <String, int>{};
    for (final entry in positions.entries) {
      final rawKey = entry.key.toString();
      final key = _canonicalCompositeKey(rawKey);
      final value = entry.value;
      if (value is! Map) continue;
      final row = Map<String, dynamic>.from(value);
      final timestamp =
          (row['timestamp'] as num?)?.toInt() ?? progressRecency[rawKey] ?? 0;
      final previousTimestamp = normalizedRecency[key];
      if (previousTimestamp == null || timestamp >= previousTimestamp) {
        normalizedPositions[key] = <String, dynamic>{
          'position': (row['position'] as num?)?.toInt() ?? 0,
          'duration': (row['duration'] as num?)?.toInt() ?? 0,
          if (timestamp > 0) 'timestamp': timestamp,
        };
        normalizedRecency[key] = timestamp;
      }
    }
    data['positions'] = normalizedPositions;

    final watched = data['watched'] as Map;
    final normalizedWatched = <String, dynamic>{};
    for (final entry in watched.entries) {
      normalizedWatched[_canonicalCompositeKey(entry.key.toString())] =
          entry.value;
    }
    data['watched'] = normalizedWatched;
  }

  String _canonicalCompositeKey(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List && decoded.isNotEmpty && decoded.first is String) {
        decoded[0] = _mainUrl(decoded.first as String);
        if (decoded.length > 1 && decoded[1] is String) {
          decoded[1] = _episodeIdentity(decoded[1] as String);
        } else if (decoded.length > 1 && decoded[1] is List) {
          final episodeIdentity = decoded[1] as List;
          if (episodeIdentity.length > 1 &&
              episodeIdentity.first == 'url' &&
              episodeIdentity[1] is String) {
            episodeIdentity[1] = _episodeIdentity(episodeIdentity[1] as String);
          }
        }
        return jsonEncode(decoded);
      }
    } catch (_) {}
    return raw;
  }

  Map<String, int> _legacyProgressRecency(Map<String, dynamic> data) {
    final result = <String, int>{};
    for (final type in const <String>['history', 'continue']) {
      final source = data[type] as Map;
      for (final value in source.values) {
        if (value is! Map) continue;
        final row = Map<String, dynamic>.from(value);
        final mainUrl = (row['url'] ?? '').toString().trim();
        if (mainUrl.isEmpty) continue;
        final episodeUrl = (row['lastEpisodeUrl'] ?? '').toString().trim();
        final timestamp = (row['timestamp'] as num?)?.toInt() ?? 0;
        final key = jsonEncode([mainUrl, episodeUrl]);
        final previous = result[key];
        if (previous == null || timestamp > previous) result[key] = timestamp;
      }
    }
    return result;
  }

  Map<String, dynamic> _riftHistorySnapshot(
    Map<String, dynamic> row,
    String url,
  ) => <String, dynamic>{
    'title': row['title'],
    'url': url,
    'posterUrl': _riftResourceUrl(row['posterUrl']),
    'bannerUrl': _riftResourceUrl(row['bannerUrl']),
    'description': row['description'],
    'contentType': row['contentType'] ?? row['type'],
    'catalogType': row['catalogType'],
    'year': row['year'],
    'isDubbed': row['isDubbed'] == true,
    'provider': providerId,
    'tmdbId': row['tmdbId'],
    'imdbId': row['imdbId'],
    'position': (row['position'] as num?)?.toInt() ?? 0,
    'duration': (row['duration'] as num?)?.toInt() ?? 0,
    if (row['progress'] is num) 'progress': row['progress'],
    'lastEpisodeUrl': _episodeStorageUrl(row['lastEpisodeUrl']?.toString()),
    'lastEpisodeIdentity': _episodeIdentity(
      (row['lastEpisodeIdentity'] ?? row['lastEpisodeUrl'])?.toString(),
    ),
    'lastStreamUrl': null,
    'season': row['season'],
    'episode': row['episode'],
    'episodeTitle': row['episodeTitle'],
    'episodeServerName': row['episodeServerName'],
    'episodeServerNumber': row['episodeServerNumber'],
    'episodePosterUrl': _riftResourceUrl(row['episodePosterUrl']),
    'timestamp': (row['timestamp'] as num?)?.toInt() ?? 0,
  };

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
      jsonEncode([_mainUrl(mainUrl), _episodeIdentity(episodeUrl)]);
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
    int? timestamp,
  }) => {
    'title': item.title,
    'url': _mainUrl(item.url),
    'posterUrl': providerId == animeRiftProviderId
        ? _riftResourceUrl(item.posterUrl)
        : item.posterUrl,
    'bannerUrl': providerId == animeRiftProviderId
        ? _riftResourceUrl(item.bannerUrl)
        : item.bannerUrl,
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
    'lastEpisodeUrl': _episodeStorageUrl(episodeUrl),
    if (providerId == animeRiftProviderId)
      'lastEpisodeIdentity': _episodeIdentity(episodeUrl),
    'lastStreamUrl': providerId == animeRiftProviderId ? null : lastStreamUrl,
    'season': season,
    'episode': episode,
    'episodeTitle': episodeTitle,
    'episodeServerName': episodeServerName,
    'episodeServerNumber': episodeServerNumber,
    'episodePosterUrl': providerId == animeRiftProviderId
        ? _riftResourceUrl(episodePosterUrl)
        : episodePosterUrl,
    'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
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
    final mainUrl = _mainUrl(item.url);
    final p =
        (data['positions'] as Map)[_positionKey(mainUrl, episodeUrl)] as Map?;
    (data['history'] as Map)[mainUrl] = _entry(
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
    final mainUrl = _mainUrl(item.url);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
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
      timestamp: timestamp,
    );
    (data['continue'] as Map)[mainUrl] = entry;
    (data['history'] as Map)[mainUrl] = entry;
    (data['positions'] as Map)[_positionKey(mainUrl, episodeUrl)] = {
      'position': position,
      'duration': duration,
      'timestamp': timestamp,
    };
  });

  Future<void> updateHistory(HistoryItem item, int timestamp, int position) =>
      _write((data) {
        final mainUrl = _mainUrl(item.item.url);
        final entry = (data['history'] as Map)[mainUrl];
        if (entry is! Map) return;
        entry['timestamp'] = timestamp;
        entry['position'] = position;
        final storedIdentity = providerId == animeRiftProviderId
            ? entry['lastEpisodeIdentity']?.toString()
            : null;
        final key = _positionKey(
          mainUrl,
          storedIdentity?.isNotEmpty == true
              ? storedIdentity
              : item.lastEpisodeUrl,
        );
        final progress = (data['positions'] as Map)[key];
        if (progress is Map) progress['position'] = position;
      });

  String _watchedKey(String mainUrl, Episode episode) => jsonEncode([
    _mainUrl(mainUrl),
    episode.url.trim().isNotEmpty
        ? ['url', _episodeIdentity(episode.url), episode.dubStatus.name]
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

  Future<void> clearContinueWatching() => _write((data) {
    (data['continue'] as Map).clear();
    _removeOrphanedPositions(data);
  });
  Future<void> removeContinueWatching(String url) => _write((data) {
    (data['continue'] as Map).remove(_mainUrl(url));
    _removeOrphanedPositions(data);
  });
  Future<void> completeMovie(String url) => _write((data) {
    final mainUrl = _mainUrl(url);
    (data['continue'] as Map).remove(mainUrl);
    (data['positions'] as Map).remove(_positionKey(mainUrl, null));
    final entry = (data['history'] as Map)[mainUrl];
    if (entry is Map) {
      entry['position'] = 0;
      entry['duration'] = 0;
    }
  });
  Future<void> clearHistory() => _write((data) {
    (data['history'] as Map).clear();
    _removeOrphanedPositions(data);
  });
  Future<void> removeHistory(String url) => _write((data) {
    (data['history'] as Map).remove(_mainUrl(url));
    _removeOrphanedPositions(data);
  });

  void _removeOrphanedPositions(Map<String, dynamic> data) {
    final history = data['history'] as Map;
    final watching = data['continue'] as Map;
    final positions = data['positions'] as Map;
    final stale = <dynamic>[];
    for (final key in positions.keys) {
      try {
        final decoded = jsonDecode(key.toString());
        if (decoded is! List || decoded.isEmpty) continue;
        final mainUrl = _mainUrl(decoded.first.toString());
        if (!history.containsKey(mainUrl) && !watching.containsKey(mainUrl)) {
          stale.add(key);
        }
      } catch (_) {}
    }
    for (final key in stale) {
      positions.remove(key);
    }
  }
}

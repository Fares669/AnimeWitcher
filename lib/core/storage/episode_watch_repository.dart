import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_providers.dart';
import '../account/animewitcher_account_service.dart';
import '../domain/entity/multimedia_item.dart';
import '../utils/safe_uri.dart';
import 'history_repository.dart';
import 'storage_service.dart';
import 'provider_local_history.dart';
import 'provider_local_library.dart';
import 'anime_rift_auto_sync.dart';

bool? episodeExplicitStateFor(
  EpisodeWatchRepository repository,
  MultimediaItem item,
  Episode episode,
) => item.provider == animeRiftProviderId
    ? repository.getExplicitStateFor(item, episode)
    : repository.getExplicitState(item.url, episode);

bool episodeIsWatchedFor(
  EpisodeWatchRepository repository,
  MultimediaItem item,
  Episode episode,
) => item.provider == animeRiftProviderId
    ? repository.isWatchedFor(item, episode)
    : repository.isWatched(item.url, episode);

Future<void> setEpisodeWatchedFor(
  EpisodeWatchRepository repository,
  MultimediaItem item,
  Episode episode,
  bool watched,
) => item.provider == animeRiftProviderId
    ? repository.setWatchedFor(item, episode, watched)
    : repository.setWatched(item.url, episode, watched);

Future<void> setEpisodesWatchedFor(
  EpisodeWatchRepository repository,
  MultimediaItem item,
  Iterable<Episode> episodes,
  bool watched,
) => item.provider == animeRiftProviderId
    ? repository.setManyWatchedFor(item, episodes, watched)
    : repository.setManyWatched(item.url, episodes, watched);

Future<void> reconcileEpisodeWatchFor(
  EpisodeWatchRepository repository,
  MultimediaItem item,
  Iterable<Episode> episodes,
) => item.provider == animeRiftProviderId
    ? Future<void>.value()
    : repository.reconcileWithCloud(item.url, episodes);

final episodeWatchRevisionProvider =
    NotifierProvider<EpisodeWatchRevision, int>(EpisodeWatchRevision.new);

class EpisodeWatchRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() {
    state++;
  }
}

final episodeWatchRepositoryProvider = Provider<EpisodeWatchRepository>((ref) {
  return EpisodeWatchRepository(
    ref.watch(storageServiceProvider),
    ref.watch(historyRepositoryProvider),
    ref.watch(animeWitcherAccountServiceProvider),
    () => ref.read(episodeWatchRevisionProvider.notifier).bump(),
    () => ref.read(riftAutoSyncProvider).scheduleLocalChange(),
    (url, number, watched) =>
        ref.read(riftAutoSyncProvider).queueWatched(url, number, watched),
    (url, numbers, watched) =>
        ref.read(riftAutoSyncProvider).queueWatchedMany(url, numbers, watched),
  );
});

class EpisodeWatchRepository {
  EpisodeWatchRepository(
    this._storageService,
    this._historyRepository,
    this._accountService,
    this._notifyChanged, [
    this._onRiftLocalChange,
    this._onRiftWatchedChange,
    this._onRiftWatchedMany,
  ]);

  final StorageService _storageService;
  final HistoryRepository _historyRepository;
  final AnimeWitcherAccountService _accountService;
  final void Function() _notifyChanged;
  final Future<void> Function()? _onRiftLocalChange;
  final Future<void> Function(String url, num episodeNumber, bool watched)?
  _onRiftWatchedChange;
  final Future<void> Function(String url, Set<num> numbers, bool watched)?
  _onRiftWatchedMany;

  /// Native Rift can have special episodes numbered 12.5, while the shared
  /// Episode.episode index must remain an int for other providers.
  num _riftServerNumber(Episode episode) {
    final actual = num.tryParse(episode.serverNumber ?? '');
    return actual != null && actual.isFinite ? actual : episode.episode;
  }

  static const String _legacyStorageKey = 'episode_watch_overrides_v1';
  static const String _storageKey = 'episode_watch_states_v2';
  static const String _cloudMigrationPrefix = 'episode_watch_cloud_migrated_v1';

  Map<String, _EpisodeWatchState>? _cachedStates;

  String _canonicalMainUrl(String mainUrl) {
    final value = mainUrl.trim();
    final uri = safeTryParseUri(value);
    if (uri == null) return value;

    // Search/home results can carry the original hit query while the details
    // page is reopened with the canonical AnimeWitcher route. Those URLs
    // identify the same anime, so query data must not affect watch state.
    final host = uri.host.toLowerCase();
    if ((host == 'animewitcher.com' || host == 'www.animewitcher.com') &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first == 'watch') {
      return uri.replace(query: '', fragment: '').toString();
    }
    return value;
  }

  String _stableEpisodeId(Episode episode) {
    final episodeUrl = episode.url.trim();
    if (episodeUrl.isNotEmpty) {
      // Episode URLs are the provider's actual episode identity. Using the
      // season/number pair here caused a watched episode to disappear when
      // AniZip enrichment changed the season value or when AnimeWitcher
      // returned a duplicate/renumbered document.
      return ['url', episodeUrl, episode.dubStatus.name].join(':');
    }

    return [
      'number',
      episode.season,
      episode.episode,
      episode.name,
      episode.dubStatus.name,
    ].join(':');
  }

  String _episodeKey(Episode episode) {
    // v2 intentionally keys a non-empty episode by its own stable URL rather
    // than by the transient parent item URL and mutable metadata fields.
    final identity = 'episode_watch_v2|${_stableEpisodeId(episode)}';
    return sha256.convert(utf8.encode(identity)).toString();
  }

  String _legacyEpisodeKey(String mainUrl, Episode episode) {
    final stableEpisodeId = episode.episode > 0
        ? [episode.season, episode.episode, episode.dubStatus.name].join(':')
        : [episode.url, episode.name, episode.dubStatus.name].join(':');

    return sha256
        .convert(utf8.encode('${_canonicalMainUrl(mainUrl)}|$stableEpisodeId'))
        .toString();
  }

  Map<String, _EpisodeWatchState> _readStates() {
    final cached = _cachedStates;
    if (cached != null) {
      return cached;
    }

    final raw = _storageService.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final states = <String, _EpisodeWatchState>{};
          decoded.forEach((dynamic key, dynamic value) {
            if (value is Map) {
              states[key.toString()] = _EpisodeWatchState.fromJson(
                Map<String, dynamic>.from(value),
              );
            }
          });
          return _cachedStates = states;
        }
      } catch (_) {
        // Fall through to the v1 migration.
      }
    }

    final legacyRaw = _storageService.getString(_legacyStorageKey);
    if (legacyRaw == null || legacyRaw.isEmpty) {
      return _cachedStates = <String, _EpisodeWatchState>{};
    }
    try {
      final decoded = jsonDecode(legacyRaw);
      if (decoded is! Map) {
        return _cachedStates = <String, _EpisodeWatchState>{};
      }
      return _cachedStates = decoded.map<String, _EpisodeWatchState>(
        (key, value) => MapEntry(
          key.toString(),
          _EpisodeWatchState(watched: value == true),
        ),
      );
    } catch (_) {
      return _cachedStates = <String, _EpisodeWatchState>{};
    }
  }

  Future<void> _persist(Map<String, _EpisodeWatchState> states) async {
    _cachedStates = states;
    await _storageService.setString(
      _storageKey,
      jsonEncode(
        states.map<String, dynamic>(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      ),
    );
    await _storageService.remove(_legacyStorageKey);
    _notifyChanged();
  }

  ProviderLocalHistory _local() =>
      ProviderLocalHistory(_storageService, animeRiftProviderId);

  bool? getExplicitStateFor(MultimediaItem item, Episode episode) =>
      item.provider == animeRiftProviderId
      ? _local().isWatched(item.url, episode)
      : getExplicitState(item.url, episode);

  bool isWatchedFor(MultimediaItem item, Episode episode) {
    if (item.provider != animeRiftProviderId) {
      return isWatched(item.url, episode);
    }
    final explicit = _local().isWatched(item.url, episode);
    if (explicit != null) return explicit;
    final position = _local().position(item.url, episode.url);
    final duration = _local().duration(item.url, episode.url);
    return duration > 0 && position / duration >= 0.90;
  }

  Future<void> setWatchedFor(
    MultimediaItem item,
    Episode episode,
    bool watched,
  ) async {
    if (item.provider != animeRiftProviderId) {
      return setWatched(item.url, episode, watched);
    }
    await _local().setWatched(item.url, episode, watched);
    _notifyChanged();
    final number = _riftServerNumber(episode);
    if (number > 0 && _onRiftWatchedChange != null) {
      await _onRiftWatchedChange(item.url, number, watched);
    } else {
      await _onRiftLocalChange?.call();
    }
  }

  Future<void> setManyWatchedFor(
    MultimediaItem item,
    Iterable<Episode> episodes,
    bool watched,
  ) async {
    if (item.provider != animeRiftProviderId) {
      return setManyWatched(item.url, episodes, watched);
    }
    final selectedEpisodes = episodes.toList(growable: false);
    await _local().setManyWatched(item.url, selectedEpisodes, watched);
    _notifyChanged();
    if (_onRiftWatchedChange == null && _onRiftWatchedMany == null) {
      await _onRiftLocalChange?.call();
      return;
    }
    final numbers = selectedEpisodes
        .map(_riftServerNumber)
        .where((number) => number.isFinite && number > 0 && number <= 100000)
        .toSet();
    if (_onRiftWatchedMany case final batch?) {
      await batch(item.url, numbers, watched);
    } else if (_onRiftWatchedChange case final single?) {
      for (final number in numbers) {
        await single(item.url, number, watched);
      }
    }
  }

  bool? getExplicitState(String mainUrl, Episode episode) {
    final states = _readStates();
    final current = _visibleState(states[_episodeKey(episode)]);
    if (current != null) return current.watched;

    // Read states written by v1 so existing users do not lose their watched
    // marks after upgrading. New writes use the URL-based v2 identity above.
    return _visibleState(states[_legacyEpisodeKey(mainUrl, episode)])?.watched;
  }

  _EpisodeWatchState? _visibleState(_EpisodeWatchState? state) {
    if (state == null) return null;
    final currentUid = _accountService.accountUid;
    if (currentUid == null ||
        state.ownerUid == null ||
        state.ownerUid == currentUid) {
      return state;
    }
    return null;
  }

  bool isWatched(String mainUrl, Episode episode) {
    final explicit = getExplicitState(mainUrl, episode);
    if (explicit != null) {
      return explicit;
    }

    if (_accountService.isEpisodeWatchedCached(mainUrl, episode.url)) {
      return true;
    }

    final position = _historyRepository.getEpisodePosition(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );
    final duration = _historyRepository.getEpisodeDuration(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );

    return duration > 0 && position / duration >= 0.90;
  }

  Future<void> setWatched(String mainUrl, Episode episode, bool watched) async {
    final states = Map<String, _EpisodeWatchState>.from(_readStates());
    states[_episodeKey(episode)] = _EpisodeWatchState(
      watched: watched,
      ownerUid: _accountService.accountUid,
    );
    await _persist(states);
    _syncInBackground(
      _accountService.setEpisodeWatched(
        mainUrl: mainUrl,
        episodeUrl: episode.url,
        watched: watched,
      ),
    );
  }

  Future<void> setManyWatched(
    String mainUrl,
    Iterable<Episode> episodes,
    bool watched,
  ) async {
    final episodeList = episodes.toList(growable: false);
    final states = Map<String, _EpisodeWatchState>.from(_readStates());

    for (final episode in episodeList) {
      states[_episodeKey(episode)] = _EpisodeWatchState(
        watched: watched,
        ownerUid: _accountService.accountUid,
      );
    }

    await _persist(states);
    for (final episode in episodeList) {
      _syncInBackground(
        _accountService.setEpisodeWatched(
          mainUrl: mainUrl,
          episodeUrl: episode.url,
          watched: watched,
        ),
      );
    }
  }

  /// Reconciles the local cache with AnimeWitcher's watched array after the
  /// provider has resolved the real episode document IDs.
  ///
  /// Only an unsent local mutation may override the server. Once a mutation is
  /// acknowledged, the cloud becomes authoritative so a watched/unwatched
  /// change made on another device is not overwritten by an old local bool.
  /// Existing pre-account watched=true values are uploaded once on first sync;
  /// legacy watched=false values never erase a remote watched mark.
  Future<void> reconcileWithCloud(
    String mainUrl,
    Iterable<Episode> episodes,
  ) async {
    if (!_accountService.isSignedIn) return;
    // A details page can be opened from search/home long after the account's
    // first sync. Refresh this one document so watched changes made on another
    // device are visible immediately instead of serving a stale process cache.
    final remote = await _accountService.watchedEpisodeIds(
      mainUrl,
      refresh: true,
    );
    final states = Map<String, _EpisodeWatchState>.from(_readStates());
    final accountUid = _accountService.accountUid;
    final migrationKey = accountUid == null
        ? null
        : '$_cloudMigrationPrefix:'
              '${sha256.convert(utf8.encode('$accountUid|${_canonicalMainUrl(mainUrl)}'))}';
    final firstAccountMerge =
        migrationKey != null && _storageService.getString(migrationKey) != '1';
    var changed = false;

    for (final episode in episodes) {
      final currentKey = _episodeKey(episode);
      final legacyKey = _legacyEpisodeKey(mainUrl, episode);
      final storedState = states[currentKey] ?? states[legacyKey];
      final visibleState = _visibleState(storedState);
      final explicit = visibleState?.watched;
      final pending = _accountService.hasPendingEpisodeWatched(
        mainUrl,
        episode.url,
      );
      if (pending) {
        if (explicit != null) {
          await _accountService.setEpisodeWatched(
            mainUrl: mainUrl,
            episodeUrl: episode.url,
            watched: explicit,
          );
          states[currentKey] = _EpisodeWatchState(
            watched: explicit,
            ownerUid: accountUid,
          );
          states.remove(legacyKey);
          changed = true;
        }
        continue;
      }

      final episodeId = _decodeEpisodeId(episode.url);
      final remoteWatched =
          (episodeId != null && remote.contains(episodeId)) ||
          _accountService.isEpisodeWatchedCached(mainUrl, episode.url);

      if (firstAccountMerge &&
          storedState?.ownerUid == null &&
          explicit == true &&
          !remoteWatched) {
        await _accountService.setEpisodeWatched(
          mainUrl: mainUrl,
          episodeUrl: episode.url,
          watched: true,
        );
        states[currentKey] = _EpisodeWatchState(
          watched: true,
          ownerUid: accountUid,
        );
        states.remove(legacyKey);
        changed = true;
        continue;
      }

      final target = _EpisodeWatchState(
        watched: remoteWatched,
        ownerUid: accountUid,
      );
      if (storedState != null || remoteWatched) {
        if (states[currentKey] != target || states.containsKey(legacyKey)) {
          states[currentKey] = target;
          states.remove(legacyKey);
          changed = true;
        }
      } else {
        final removedCurrent = states.remove(currentKey) != null;
        final removedLegacy = states.remove(legacyKey) != null;
        if (removedCurrent || removedLegacy) changed = true;
      }
    }

    if (migrationKey != null && firstAccountMerge) {
      await _storageService.setString(migrationKey, '1');
    }

    if (changed) {
      await _persist(states);
    } else {
      _notifyChanged();
    }
  }

  String? _decodeEpisodeId(String rawUrl) {
    final parts = rawUrl.split('|');
    if (parts.length < 2) return null;
    final raw = parts.sublist(1).join('|');
    try {
      return safeDecodeUriComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  void _syncInBackground(Future<void> operation) {
    unawaited(
      operation.catchError((Object error) {
        if (kDebugMode) {
          debugPrint(
            '[AnimeWitcherAccount] Could not sync watched episode: $error',
          );
        }
      }),
    );
  }
}

class _EpisodeWatchState {
  const _EpisodeWatchState({required this.watched, this.ownerUid});

  final bool watched;
  final String? ownerUid;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'watched': watched,
    if (ownerUid != null) 'owner_uid': ownerUid,
  };

  factory _EpisodeWatchState.fromJson(Map<String, dynamic> json) {
    final owner = json['owner_uid']?.toString().trim();
    return _EpisodeWatchState(
      watched: json['watched'] == true,
      ownerUid: owner == null || owner.isEmpty ? null : owner,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _EpisodeWatchState &&
      other.watched == watched &&
      other.ownerUid == ownerUid;

  @override
  int get hashCode => Object.hash(watched, ownerUid);
}

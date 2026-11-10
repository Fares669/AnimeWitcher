import 'dart:async';
import 'dart:convert';

import '../extensions/providers/anime_rift_api_client.dart';
import '../utils/anime_rift_identity.dart';
import 'anime_rift_account_scope.dart';
import 'library_category.dart';
import 'anime_rift_rating.dart';
import 'storage_service.dart';

/// A desired local state, not an HTTP request. No server write contract has
/// been confirmed; keeping these records does not claim remote synchronization.
class AnimeRiftCloudPendingChange {
  const AnimeRiftCloudPendingChange({
    required this.kind,
    required this.url,
    required this.value,
    required this.revision,
  });

  final String kind;
  final String url;
  final Map<String, Object?> value;
  final int revision;

  String get key => jsonEncode([
    kind,
    url,
    value['episode_number'] ?? value['episodeIdentity'] ?? '',
  ]);

  Map<String, Object?> toJson() => {
    'kind': kind,
    'url': url,
    'value': value,
    'revision': revision,
  };

  static AnimeRiftCloudPendingChange fromJson(Object? input) {
    if (input is! Map ||
        input['kind'] is! String ||
        input['url'] is! String ||
        input['value'] is! Map ||
        input['revision'] is! int ||
        (input['revision'] as int) < 1) {
      throw const FormatException('Invalid pending Rift cloud change');
    }
    return AnimeRiftCloudPendingChange(
      kind: input['kind'] as String,
      url: input['url'] as String,
      value: Map<String, Object?>.from(input['value'] as Map),
      revision: input['revision'] as int,
    );
  }
}

/// Persist local edits by *account hash*, separate from guest and Witcher
/// storage. A local removal is a tombstone and must not be undone by a pull.
/// Writes are serialized per storage instance and account to avoid lost edits.
class AnimeRiftCloudPendingJournal {
  AnimeRiftCloudPendingJournal(this._storage);

  final StorageService _storage;
  static final _queues = Expando<Map<String, Future<void>>>();
  String? _cachedKey;
  String? _cachedRaw;
  Map<String, AnimeRiftCloudPendingChange>? _cachedChanges;

  static String? get currentAccount => AnimeRiftLocalAccountScope.accountHash;

  String storageKey(String accountHash) =>
      'animerift_cloud_pending_v1:$accountHash';

  static String catalogUrl(String url) {
    final canonical = canonicalAnimeRiftCatalogUrl(url);
    if (canonical == null ||
        !RegExp(r'^https://anime-rift\.com/anime/[A-Za-z0-9_-]+$')
            .hasMatch(canonical)) {
      throw ArgumentError.value(null, 'url', 'Not a Rift catalog identity');
    }
    return canonical;
  }

  static void requireAccount(String accountHash) {
    if (currentAccount != accountHash) {
      throw const AnimeRiftAuthenticationRequired();
    }
  }

  Map<String, AnimeRiftCloudPendingChange> _read(String accountHash) {
    final key = storageKey(accountHash);
    final raw = _storage.getString(key);
    if (_cachedKey == key && _cachedRaw == raw && _cachedChanges != null) {
      return Map.of(_cachedChanges!);
    }
    if (raw == null || raw.isEmpty) {
      _cachedKey = key;
      _cachedRaw = raw;
      _cachedChanges = {};
      return {};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['changes'] is! Map) {
      throw const FormatException('Invalid pending Rift cloud journal');
    }
    final changes = <String, AnimeRiftCloudPendingChange>{};
    (decoded['changes'] as Map).forEach((dynamic key, dynamic value) {
      final change = AnimeRiftCloudPendingChange.fromJson(value);
      if (key is! String || key != change.key) {
        throw const FormatException('Mismatched pending Rift cloud change');
      }
      changes[key] = change;
    });
    _cachedKey = key;
    _cachedRaw = raw;
    _cachedChanges = changes;
    return Map.of(changes);
  }

  List<AnimeRiftCloudPendingChange> pending(String accountHash) {
    requireAccount(accountHash);
    return List.unmodifiable(_read(accountHash).values);
  }

  bool hasPending(String accountHash, String url, String kind) {
    requireAccount(accountHash);
    return _read(accountHash).values
        .any((change) => change.url == url && change.kind == kind);
  }

  Future<void> queueFavorite(String url, bool favorite) =>
      _upsert('favorite', catalogUrl(url), {'favorite': favorite});

  Future<void> queueWatched(String url, num episodeNumber, bool viewed) {
    if (!episodeNumber.isFinite ||
        episodeNumber <= 0 ||
        episodeNumber > 100000) {
      throw ArgumentError.value(episodeNumber, 'episodeNumber');
    }
    final canonicalNumber = episodeNumber == episodeNumber.truncateToDouble()
        ? episodeNumber.toInt()
        : episodeNumber;
    return _upsert('watched', catalogUrl(url), {
      'episode_number': canonicalNumber,
      'viewed': viewed,
    });
  }

  /// Persist a user's multi-select action atomically. This does not use the
  /// unverified native watch_many HTTP contract; the verified writer still
  /// sends each desired episode state separately when flushing.
  Future<void> queueWatchedMany(
    String url,
    Iterable<num> episodeNumbers,
    bool viewed,
  ) async {
    final numbers = episodeNumbers
        .map(
          (number) => number.isFinite && number == number.truncateToDouble()
              ? number.toInt()
              : number,
        )
        .toSet();
    if (numbers.length > 10000 ||
        numbers.any(
          (number) => !number.isFinite || number <= 0 || number > 100000,
        )) {
      throw ArgumentError('Invalid Rift watched episode numbers');
    }
    if (numbers.isEmpty) return;
    final canonical = catalogUrl(url);
    final account = currentAccount;
    if (account == null) throw const AnimeRiftAuthenticationRequired();
    await _mutate(account, (changes) {
      for (final number in numbers) {
        final draft = AnimeRiftCloudPendingChange(
          kind: 'watched',
          url: canonical,
          value: {'episode_number': number, 'viewed': viewed},
          revision: 1,
        );
        final previous = changes[draft.key];
        changes[draft.key] = AnimeRiftCloudPendingChange(
          kind: draft.kind,
          url: draft.url,
          value: draft.value,
          revision: (previous?.revision ?? 0) + 1,
        );
      }
    });
    requireAccount(account);
  }

  Future<void> queueRating(String url, AnimeRiftRating rating) {
    if (!rating.isValid) throw ArgumentError('Invalid Rift rating');
    return _upsert('rating', catalogUrl(url), rating.toJson());
  }

  Future<void> queueClearRating(String url) =>
      _upsert('rating', catalogUrl(url), const {'clear': true});

  Future<void> queueCategory(String url, LibraryCategory? category) {
    if (category == LibraryCategory.favorite) {
      throw ArgumentError.value(category, 'category');
    }
    return _upsert('category', catalogUrl(url), {
      'category': category?.storageKey,
    });
  }

  /// Preserve explicit local watch-history additions and removals. The server
  /// method for deleting a history row is still unverified; this is local only.
  Future<void> queueHistory(String url, bool present) =>
      _upsert('history', catalogUrl(url), {'present': present});

  /// Mark a user-requested local clear without deleting cloud history.
  Future<void> queueHistoryClear() =>
      _upsert('history-clear', '', const {'cleared': true});

  Future<void> queuePlayback(
    String url, {
    String? episodeIdentity,
    required int position,
    required int duration,
    int? season,
    int? episode,
  }) {
    if (position < 0 ||
        duration < 0 ||
        (season != null && season < 0) ||
        (episode != null && episode < 0)) {
      throw ArgumentError('Invalid Rift playback progress');
    }
    // Signed stream URLs are never persisted as an episode identity. Only a
    // stable opaque episode ID is allowed until Rift's server schema is known.
    final stableEpisode = episodeIdentity?.trim() ?? '';
    if (stableEpisode.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(stableEpisode)) {
      throw ArgumentError.value(
        null,
        'episodeIdentity',
        'Not a stable episode ID',
      );
    }
    return _upsert('playback', catalogUrl(url), {
      'episodeIdentity': stableEpisode,
      'position': position,
      'duration': duration,
      'season': ?season,
      'episode': ?episode,
    });
  }

  /// Call after a generic local change where the exact entity is unknown.
  /// This is a durable signal for future reconciliation, not an HTTP request.
  Future<void> markDirty() => _upsert('rescan', '', const {'dirty': true});

  Future<void> _upsert(
    String kind,
    String url,
    Map<String, Object?> value,
  ) async {
    final accountHash = currentAccount;
    if (accountHash == null) throw const AnimeRiftAuthenticationRequired();
    await _mutate(accountHash, (changes) {
      final draft = AnimeRiftCloudPendingChange(
        kind: kind,
        url: url,
        value: value,
        revision: 1,
      );
      final previous = changes[draft.key];
      changes[draft.key] = AnimeRiftCloudPendingChange(
        kind: kind,
        url: url,
        value: value,
        revision: (previous?.revision ?? 0) + 1,
      );
    });
    requireAccount(accountHash);
  }

  /// Acknowledge only the exact revision successfully sent. A later local edit
  /// to the same item must remain queued even if an older send finishes.
  Future<void> acknowledge(
    String accountHash,
    AnimeRiftCloudPendingChange sent,
  ) async {
    requireAccount(accountHash);
    await _mutate(accountHash, (changes) {
      if (changes[sent.key]?.revision == sent.revision) {
        changes.remove(sent.key);
      }
    });
    requireAccount(accountHash);
  }

  Future<void> _mutate(
    String accountHash,
    void Function(Map<String, AnimeRiftCloudPendingChange>) change,
  ) {
    final key = storageKey(accountHash);
    final byKey = _queues[_storage] ??= {};
    final previous = byKey[key] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      final values = _read(accountHash);
      change(values);
      await _storage.setString(
        key,
        jsonEncode({
          'version': 1,
          'changes': {
            for (final entry in values.entries) entry.key: entry.value.toJson(),
          },
        }),
      );
    });
    byKey[key] = next;
    return next;
  }
}

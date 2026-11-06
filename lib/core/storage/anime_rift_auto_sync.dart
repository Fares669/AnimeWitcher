import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_providers.dart';
import '../extensions/extension_manager.dart';
import '../extensions/providers/anime_rift_provider.dart';
import 'anime_rift_account_scope.dart';
import 'anime_rift_cloud_pending.dart';
import 'library_category.dart';
import 'anime_rift_rating.dart';
import '../services/app_diagnostics.dart';
import 'storage_service.dart';

/// A transport with a separately verified HTTP method, body and permissions.
/// Unsupported mutations remain queued instead of being falsely acknowledged.
abstract class AnimeRiftVerifiedCloudWriter {
  /// Implementations must bind [accountHash] to the authenticated session
  /// before sending, and reject a switch rather than sending A's edit as B.
  Future<bool> write(String accountHash, AnimeRiftCloudPendingChange change);
}

class AnimeRiftCloudWriter implements AnimeRiftVerifiedCloudWriter {
  AnimeRiftCloudWriter(
    this._favorite, {
    Future<Map<String, dynamic>> Function(
      String,
      String?, {
      required String accountHash,
    })?
    setCategory,
    Future<Map<String, dynamic>> Function(String)? readCategory,
    Future<Map<String, dynamic>> Function()? readFavorites,
    Future<Map<String, dynamic>> Function(
      String,
      int,
      bool, {
      required String accountHash,
    })?
    setWatched,
    Future<Map<String, dynamic>> Function(
      String,
      AnimeRiftRating, {
      required String accountHash,
    })?
    setRating,
    Future<Map<String, dynamic>> Function(
      String, {
      required String accountHash,
    })?
    clearRating,
    Future<AnimeRiftRating?> Function(String)? readRating,
    Future<Map<String, dynamic>> Function()? readHistory,
    Future<Map<String, dynamic>> Function(
      String,
      String, {
      required String accountHash,
    })?
    clearHistoryOne,
    Future<Map<String, dynamic>> Function(
      List<String>, {
      required String accountHash,
    })?
    clearHistoryMany,
  }) : _setCategory = setCategory,
       _readCategory = readCategory,
       _readFavorites = readFavorites,
       _setWatched = setWatched,
       _setRating = setRating,
       _clearRating = clearRating,
       _readRating = readRating,
       _readHistory = readHistory,
       _clearHistoryOne = clearHistoryOne,
       _clearHistoryMany = clearHistoryMany;

  final Future<Map<String, dynamic>> Function(
    String,
    bool, {
    required String accountHash,
  })
  _favorite;
  final Future<Map<String, dynamic>> Function(
    String,
    String?, {
    required String accountHash,
  })?
  _setCategory;
  final Future<Map<String, dynamic>> Function(String)? _readCategory;
  final Future<Map<String, dynamic>> Function()? _readFavorites;
  final Future<Map<String, dynamic>> Function(
    String,
    int,
    bool, {
    required String accountHash,
  })?
  _setWatched;
  final Future<Map<String, dynamic>> Function(
    String,
    AnimeRiftRating, {
    required String accountHash,
  })?
  _setRating;
  final Future<Map<String, dynamic>> Function(
    String, {
    required String accountHash,
  })?
  _clearRating;
  final Future<AnimeRiftRating?> Function(String)? _readRating;
  final Future<Map<String, dynamic>> Function()? _readHistory;
  final Future<Map<String, dynamic>> Function(
    String,
    String, {
    required String accountHash,
  })?
  _clearHistoryOne;
  final Future<Map<String, dynamic>> Function(
    List<String>, {
    required String accountHash,
  })?
  _clearHistoryMany;

  static const _categoryKeys = {
    LibraryCategory.watching: 'currently',
    LibraryCategory.planToWatch: 'want_to',
    LibraryCategory.completed: 'finished',
    LibraryCategory.continueLater: 'later',
    LibraryCategory.notInterested: 'dropped',
  };

  // List readback must be complete and parseable before an outgoing change
  // can be acknowledged. A partial page or unexpected row stays pending.
  static Set<String>? _remoteIds(Map<String, dynamic> response) {
    final payload = response['items'];
    final items = payload is Map
        ? payload['items'] ?? payload['data'] ?? payload['results']
        : payload;
    if (items is! List ||
        response['hasNext'] == true ||
        (payload is Map && payload['hasNext'] == true)) {
      return null;
    }
    final ids = <String>{};
    for (final row in items) {
      if (row is! Map) return null;
      final embedded = row['anime'] is Map
          ? row['anime'] as Map
          : row['_anime'] is Map
          ? row['_anime'] as Map
          : null;
      final anime = embedded ?? row;
      final rawId = embedded != null
          ? anime['_id'] ?? anime['anime_id'] ?? anime['animeId']
          : row['anime_id'] ??
                row['animeId'] ??
                row['_anime'] ??
                row['anime'] ??
                row['_id'];
      if (rawId is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(rawId)) {
        return null;
      }
      ids.add(rawId);
    }
    return ids;
  }

  /// A history record has its own ID and its anime's catalog ID. Never send a
  /// catalogue ID as a history-record ID, or delete on a partial response.
  static List<(String recordId, String animeId)>? _historyRows(
    Map<String, dynamic> response,
  ) {
    final payload = response['items'];
    final rows = payload is Map
        ? payload['items'] ?? payload['data'] ?? payload['results']
        : payload;
    if (rows is! List ||
        response['hasNext'] == true ||
        (payload is Map && payload['hasNext'] == true)) {
      return null;
    }
    final result = <(String, String)>[];
    final safe = RegExp(r'^[A-Za-z0-9_-]+$');
    for (final row in rows) {
      if (row is! Map) return null;
      final embedded = row['anime'] is Map
          ? row['anime'] as Map
          : row['_anime'] is Map
          ? row['_anime'] as Map
          : null;
      final recordId = row['_id'] ?? row['id'];
      final animeId =
          embedded?['_id'] ??
          embedded?['anime_id'] ??
          row['anime_id'] ??
          row['animeId'];
      if (recordId is! String ||
          animeId is! String ||
          !safe.hasMatch(recordId) ||
          !safe.hasMatch(animeId)) {
        return null;
      }
      result.add((recordId, animeId));
    }
    return result;
  }

  @override
  Future<bool> write(
    String accountHash,
    AnimeRiftCloudPendingChange change,
  ) async {
    if (change.kind != 'favorite' &&
        change.kind != 'category' &&
        change.kind != 'watched' &&
        change.kind != 'rating' &&
        change.kind != 'history' &&
        change.kind != 'history-clear') {
      return false;
    }
    AnimeRiftCloudPendingJournal.requireAccount(accountHash);
    if (change.kind == 'history-clear' ||
        (change.kind == 'history' && change.value['present'] == false)) {
      final reader = _readHistory;
      if (reader == null) return false;
      final remote = _historyRows(await reader());
      AnimeRiftCloudPendingJournal.requireAccount(accountHash);
      if (remote == null) return false;
      if (change.kind == 'history-clear') {
        final clearMany = _clearHistoryMany;
        if (clearMany == null) return false;
        if (remote.isNotEmpty) {
          await clearMany(
            remote.map((row) => row.$1).toList(),
            accountHash: accountHash,
          );
          AnimeRiftCloudPendingJournal.requireAccount(accountHash);
        }
        final verified = _historyRows(await reader());
        AnimeRiftCloudPendingJournal.requireAccount(accountHash);
        return verified != null && verified.isEmpty;
      }
      final id = Uri.parse(AnimeRiftCloudPendingJournal.catalogUrl(change.url))
          .pathSegments
          .last;
      final remove = _clearHistoryOne;
      if (remove == null) return false;
      for (final row in remote.where((row) => row.$2 == id)) {
        await remove(row.$1, id, accountHash: accountHash);
        AnimeRiftCloudPendingJournal.requireAccount(accountHash);
      }
      final verified = _historyRows(await reader());
      AnimeRiftCloudPendingJournal.requireAccount(accountHash);
      return verified != null && !verified.any((row) => row.$2 == id);
    }
    if (change.kind == 'history') return false;
    final url = Uri.parse(AnimeRiftCloudPendingJournal.catalogUrl(change.url));
    final id = url.pathSegments.last;
    if (change.kind == 'favorite') {
      final favorite = change.value['favorite'];
      if (favorite is! bool) {
        throw const FormatException('Invalid Rift favorite');
      }
      await _favorite(id, favorite, accountHash: accountHash);
      AnimeRiftCloudPendingJournal.requireAccount(accountHash);
      if (_readFavorites != null) {
        final current = _remoteIds(await _readFavorites());
        AnimeRiftCloudPendingJournal.requireAccount(accountHash);
        return current != null && current.contains(id) == favorite;
      }
    } else if (change.kind == 'watched') {
      final setter = _setWatched;
      if (setter == null) return false;
      final number = change.value['episode_number'];
      final viewed = change.value['viewed'];
      if (number is! int || number <= 0 || viewed is! bool) {
        throw const FormatException('Invalid Rift watched episode state');
      }
      await setter(id, number, viewed, accountHash: accountHash);
      AnimeRiftCloudPendingJournal.requireAccount(accountHash);
      // The native endpoint acknowledges the desired episode state. Remote
      // episode-by-episode GET verification is not guaranteed by this API.
      return true;
    } else if (change.kind == 'rating') {
      final readback = _readRating;
      if (readback == null) return false;
      if (change.value['clear'] == true) {
        final clear = _clearRating;
        if (clear == null) return false;
        await clear(id, accountHash: accountHash);
      } else {
        final setter = _setRating;
        if (setter == null) return false;
        final rating = AnimeRiftRating.fromMap(change.value);
        if (rating == null) throw const FormatException('Invalid Rift rating');
        await setter(id, rating, accountHash: accountHash);
      }
      AnimeRiftCloudPendingJournal.requireAccount(accountHash);
      final remote = await readback(change.url);
      AnimeRiftCloudPendingJournal.requireAccount(accountHash);
      if (change.value['clear'] == true) return remote == null;
      return remote == AnimeRiftRating.fromMap(change.value);
    } else {
      final setCategory = _setCategory;
      final readCategory = _readCategory;
      if (setCategory == null || readCategory == null) return false;
      final raw = change.value['category'];
      if (raw != null && raw is! String) {
        throw const FormatException('Invalid Rift category');
      }
      final desired = raw == null
          ? null
          : _categoryKeys[LibraryCategory.fromStorageKey(raw as String)];
      if (raw != null && desired == null) {
        throw const FormatException('Unrecognized Rift category');
      }
      await setCategory(id, desired, accountHash: accountHash);
      AnimeRiftCloudPendingJournal.requireAccount(accountHash);
      // The native request's accepted status is not proof that the remote
      // list actually changed. Confirm all built-in list memberships before
      // acknowledging a move/removal, including after an eventual-consistency
      // delay. Pending edits protect local state from a stale cloud pull.
      final memberships = <String>[];
      for (final key in _categoryKeys.values) {
        final response = await readCategory(key);
        AnimeRiftCloudPendingJournal.requireAccount(accountHash);
        final ids = _remoteIds(response);
        if (ids == null) return false;
        if (ids.contains(id)) memberships.add(key);
      }
      return desired == null
          ? memberships.isEmpty
          : memberships.length == 1 && memberships.single == desired;
    }
    AnimeRiftCloudPendingJournal.requireAccount(accountHash);
    return true;
  }
}

/// Account-scoped automatic pull and durable local-change journal. Never reads
/// or logs AnimeWitcher account credentials, and never sends speculative Rift
/// requests. Local edits remain queued until a verified writer is available.
class AnimeRiftAutoSyncCoordinator {
  AnimeRiftAutoSyncCoordinator({
    required StorageService storage,
    required AnimeRiftProvider? Function() activeRift,
    AnimeRiftVerifiedCloudWriter? verifiedWriter,
    void Function()? onImported,
    Duration debounce = const Duration(seconds: 3),
  }) : _storage = storage,
       _activeRift = activeRift,
       _writer = verifiedWriter,
       _onImported = onImported,
       _debounce = debounce,
       _journal = AnimeRiftCloudPendingJournal(storage);

  final StorageService _storage;
  final AnimeRiftProvider? Function() _activeRift;
  final AnimeRiftVerifiedCloudWriter? _writer;
  final void Function()? _onImported;
  final Duration _debounce;
  final AnimeRiftCloudPendingJournal _journal;
  final Map<String, ({DateTime when, int position})> _playbackSnapshots = {};

  Future<void>? _inFlight;
  Timer? _debounceTimer;
  bool _refreshRequested = false;
  bool _pendingFlushRequested = false;
  bool _ratingFlushRequested = false;
  final Set<String> _ratingFlushUrls = {};
  final Set<LibraryCategory> _requestedCategories = {};
  bool _requestedHistory = false;
  bool _disposed = false;
  Object? _lastError;

  Object? get lastError => _lastError;
  bool get isSyncing => _inFlight != null;
  bool get canPushToCloud => _writer != null;

  bool get _canRecordLocalChange =>
      !_disposed &&
      _activeRift() != null &&
      AnimeRiftLocalAccountScope.accountHash != null;

  /// Call on app startup, foreground resume or Rift account/provider change.
  /// Concurrent requests coalesce, and requests arriving mid-sync cause one
  /// additional pass without overlapping cloud reads/writes.
  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _refreshRequested = true;
    return _beginRefresh();
  }

  /// Refresh just the visible shelf. Requests are serialized with full
  /// background sync and pending mutations are uploaded before each pull.
  Future<void> refreshCategory(LibraryCategory category) {
    if (_disposed) return Future<void>.value();
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _requestedCategories.add(category);
    return _beginRefresh();
  }

  Future<void> refreshHistory() {
    if (_disposed) return Future<void>.value();
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _requestedHistory = true;
    return _beginRefresh();
  }

  /// Flush local edits without fetching all cloud shelves. Frequent playback
  /// progress and favorite/rating changes must never trigger a full import.
  Future<void> flushPending() {
    if (_disposed) return Future<void>.value();
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingFlushRequested = true;
    return _beginRefresh();
  }

  /// Push only pending rating edits, without waiting for a full catalog pull.
  /// A false result means the desired state remains durable but unconfirmed.
  Future<bool> pushRatingNow(String url) async {
    final account = AnimeRiftLocalAccountScope.accountHash;
    if (account == null || !_canRecordLocalChange) {
      throw const AnimeRiftAuthenticationRequired();
    }
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _ratingFlushRequested = true;
    _ratingFlushUrls.add(AnimeRiftCloudPendingJournal.catalogUrl(url));
    await _beginRefresh();
    AnimeRiftCloudPendingJournal.requireAccount(account);
    return !_journal.hasPending(
      account,
      AnimeRiftCloudPendingJournal.catalogUrl(url),
      'rating',
    );
  }

  Future<void> _beginRefresh() {
    final running = _inFlight;
    if (running != null) return running;
    final operation = _drain();
    _inFlight = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
  }

  /// Generic mutation hook when the caller has no precise item details.
  /// Detailed hooks below are preferable: they retain removals and protect
  /// newer local changes from an older remote snapshot.
  Future<void> scheduleLocalChange() async {
    // Rift guest changes stay local. Never create a fake linked-account scope.
    if (!_canRecordLocalChange) return;
    await _journal.markDirty();
    _scheduleRefresh();
  }

  Future<void> queueFavorite(String url, bool favorite) async {
    if (!_canRecordLocalChange) return;
    await _journal.queueFavorite(url, favorite);
    _scheduleRefresh();
  }

  Future<void> queueCategory(String url, LibraryCategory? category) async {
    if (!_canRecordLocalChange) return;
    await _journal.queueCategory(url, category);
    _scheduleRefresh();
  }

  Future<void> queueHistory(String url, bool present) async {
    if (!_canRecordLocalChange) return;
    await _journal.queueHistory(url, present);
    _scheduleRefresh();
  }

  Future<void> queueHistoryClear() async {
    if (!_canRecordLocalChange) return;
    await _journal.queueHistoryClear();
    _scheduleRefresh();
  }

  Future<void> queueWatched(String url, int episodeNumber, bool viewed) async {
    if (!_canRecordLocalChange) return;
    await _journal.queueWatched(url, episodeNumber, viewed);
    _scheduleRefresh();
  }

  Future<void> queueRating(String url, AnimeRiftRating rating) async {
    if (!_canRecordLocalChange) return;
    await _journal.queueRating(url, rating);
    _scheduleRefresh();
  }

  Future<void> queueClearRating(String url) async {
    if (!_canRecordLocalChange) throw const AnimeRiftAuthenticationRequired();
    await _journal.queueClearRating(url);
    _scheduleRefresh();
  }

  bool hasPendingRating(String url) {
    if (!_canRecordLocalChange) return false;
    final account = AnimeRiftLocalAccountScope.accountHash!;
    return _journal.hasPending(
      account,
      AnimeRiftCloudPendingJournal.catalogUrl(url),
      'rating',
    );
  }

  AnimeRiftRating? pendingRating(String url) {
    if (!_canRecordLocalChange) return null;
    final account = AnimeRiftLocalAccountScope.accountHash!;
    final canonical = AnimeRiftCloudPendingJournal.catalogUrl(url);
    for (final change in _journal.pending(account)) {
      if (change.kind == 'rating' && change.url == canonical) {
        return AnimeRiftRating.fromMap(change.value);
      }
    }
    return null;
  }

  Future<void> queuePlayback(
    String url, {
    String? episodeIdentity,
    required int position,
    required int duration,
    int? season,
    int? episode,
  }) async {
    if (!_canRecordLocalChange) return;
    final account = AnimeRiftLocalAccountScope.accountHash!;
    final key = '$account|$url|${episodeIdentity ?? ''}';
    final now = DateTime.now();
    final previous = _playbackSnapshots[key];
    // The player may report progress several times a second. Its local
    // position remains precise in ProviderLocalHistory; only cloud snapshots
    // are rate-limited to avoid repeated disk writes and network refreshes.
    final nearCompletion = duration > 0 && position >= duration * 0.90;
    final crossedCompletion =
        nearCompletion &&
        previous != null &&
        previous.position < duration * 0.90;
    if (previous != null &&
        now.difference(previous.when) < const Duration(seconds: 15) &&
        (position - previous.position).abs() < 20 &&
        !crossedCompletion) {
      return;
    }
    await _journal.queuePlayback(
      url,
      episodeIdentity: episodeIdentity,
      position: position,
      duration: duration,
      season: season,
      episode: episode,
    );
    if (nearCompletion && episode != null && episode > 0) {
      await _journal.queueWatched(url, episode, true);
    }
    _playbackSnapshots[key] = (when: now, position: position);
    if (_playbackSnapshots.length > 128) {
      _playbackSnapshots.remove(_playbackSnapshots.keys.first);
    }
    _scheduleRefresh();
  }

  void _scheduleRefresh() {
    // Inbound reads happen on startup, resume and account/provider changes.
    // Without a verified cloud writer, fetching the same remote lists for
    // every local progress tick achieves nothing and can saturate the gateway.
    if (_disposed || _writer == null) return;
    // A frequently updating player must not postpone syncing forever.
    if (_debounceTimer?.isActive == true) return;
    _debounceTimer = Timer(_debounce, () {
      _debounceTimer = null;
      unawaited(
        flushPending().catchError((Object error, StackTrace _) {
          _lastError = error;
          // Safe to retry on the next change or lifecycle event. Do not print
          // errors that might contain a signed URL or an account credential.
        }),
      );
    });
  }

  Future<void> _drain() async {
    final elapsed = Stopwatch()..start();
    var passes = 0;
    try {
      do {
        passes++;
        final all = _refreshRequested;
        final categories = Set<LibraryCategory>.of(_requestedCategories);
        final history = _requestedHistory;
        final pendingOnly = _pendingFlushRequested;
        final ratings = _ratingFlushRequested;
        final ratingUrls = Set<String>.of(_ratingFlushUrls);
        _refreshRequested = false;
        _pendingFlushRequested = false;
        _ratingFlushRequested = false;
        _ratingFlushUrls.clear();
        _requestedCategories.clear();
        _requestedHistory = false;
        final provider = _activeRift();
        if (provider == null || !await provider.restoreAccountSession()) {
          continue;
        }
        final account = AnimeRiftLocalAccountScope.accountHash;
        if (account == null) continue;

        appDiagnostics.record('rift.sync.phase', {
          'status': all
              ? 'full'
              : categories.isNotEmpty
              ? 'shelf'
              : history
              ? 'history'
              : ratings
              ? 'rating'
              : pendingOnly
              ? 'pending'
              : 'idle',
          'count': passes,
        });

        // A verified writer flushes pending local changes BEFORE pulling,
        // preventing an older server snapshot from overriding a recent edit.
        // Without one, retain every mutation durably and only perform GETs.
        if (_writer != null) {
          await _pushPending(
            account,
            ratingUrls: ratings && !all ? ratingUrls : null,
            kinds: all || pendingOnly
                ? null
                : {
                    if (categories.isNotEmpty) ...['favorite', 'category'],
                    if (history) ...[
                      'history',
                      'history-clear',
                      'watched',
                      'playback',
                    ],
                    if (ratings) 'rating',
                  },
          );
        }
        AnimeRiftCloudPendingJournal.requireAccount(account);
        if (all) {
          final result = await provider.importCloudLibrary(_storage);
          AnimeRiftCloudPendingJournal.requireAccount(account);
          if (!_disposed && result.changed > 0) _onImported?.call();
        } else {
          for (final category in categories) {
            final result = await provider.importCloudLibraryCategory(
              _storage,
              category,
            );
            AnimeRiftCloudPendingJournal.requireAccount(account);
            if (!_disposed && result.changed > 0) _onImported?.call();
          }
          if (history) {
            final result = await provider.importCloudHistory(_storage);
            AnimeRiftCloudPendingJournal.requireAccount(account);
            if (!_disposed && result.changed > 0) _onImported?.call();
          }
        }
        _lastError = null;
      } while ((_refreshRequested ||
              _pendingFlushRequested ||
              _ratingFlushRequested ||
              _requestedCategories.isNotEmpty ||
              _requestedHistory) &&
          !_disposed);
      appDiagnostics.record('rift.sync.complete', {
        'durationMs': elapsed.elapsedMilliseconds,
        'count': passes,
      });
    } catch (error) {
      _lastError = error;
      appDiagnostics.record('rift.sync.error', {
        'durationMs': elapsed.elapsedMilliseconds,
        'count': passes,
        'errorType': error.runtimeType.toString(),
      });
      rethrow;
    }
  }

  Future<void> _pushPending(
    String account, {
    Set<String>? kinds,
    Set<String>? ratingUrls,
  }) async {
    final writer = _writer;
    if (writer == null) return;
    final changes = _journal.pending(account);
    for (final change in changes) {
      AnimeRiftCloudPendingJournal.requireAccount(account);
      if (change.kind == 'rescan') continue;
      if (kinds != null && !kinds.contains(change.kind)) continue;
      if (ratingUrls != null &&
          change.kind == 'rating' &&
          !ratingUrls.contains(change.url)) {
        continue;
      }
      bool acknowledged;
      try {
        acknowledged = await writer.write(account, change);
      } on AnimeRiftAccessUnavailable catch (error) {
        AnimeRiftCloudPendingJournal.requireAccount(account);
        final status = error.statusCode;
        // A non-auth 4xx rejection belongs to this one queued edit. Preserve
        // it for inspection/retry, but don't starve unrelated library edits.
        // Offline, rate-limit and server outages still stop the batch.
        if (status == null ||
            status < 400 ||
            status >= 500 ||
            status == 401 ||
            status == 403 ||
            status == 429) {
          rethrow;
        }
        appDiagnostics.record('rift.sync.writeRejected', {
          'status': change.kind,
          'httpStatus': status,
        });
        continue;
      }
      if (!acknowledged) continue;
      AnimeRiftCloudPendingJournal.requireAccount(account);
      await _journal.acknowledge(account, change);
    }
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
  }
}

/// Initialize by reading this provider once in the app shell. Native Witcher
/// account state remains unrelated and untouched. The app shell also calls
/// refresh() on startup/resume; mutation controllers call the typed queue hooks.
final riftAutoSyncProvider = Provider<AnimeRiftAutoSyncCoordinator>((ref) {
  AnimeRiftProvider? activeRift() {
    final provider = ref.read(activeProviderProvider);
    return provider is AnimeRiftProvider ? provider : null;
  }

  final coordinator = AnimeRiftAutoSyncCoordinator(
    storage: ref.read(storageServiceProvider),
    activeRift: activeRift,
    verifiedWriter: AnimeRiftCloudWriter(
      (id, favorite, {required accountHash}) {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.setCloudFavorite(
          id,
          favorite,
          accountHash: accountHash,
        );
      },
      setCategory: (id, category, {required accountHash}) {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.setCloudCategory(
          id,
          category,
          accountHash: accountHash,
        );
      },
      readCategory: (category) {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.fetchCloudCategory(category);
      },
      readFavorites: () {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.fetchCloudFavorites();
      },
      setWatched: (id, number, viewed, {required accountHash}) {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.setCloudEpisodeWatched(
          id,
          number,
          viewed,
          accountHash: accountHash,
        );
      },
      setRating: (id, rating, {required accountHash}) {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.setCloudRating(id, rating, accountHash: accountHash);
      },
      clearRating: (id, {required accountHash}) {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.clearCloudRating(id, accountHash: accountHash);
      },
      readRating: (url) {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.fetchCloudRating(url);
      },
      readHistory: () {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.fetchCloudWatchHistory();
      },
      clearHistoryOne: (recordId, animeId, {required accountHash}) {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.clearCloudWatchHistoryRecord(
          recordId,
          animeId,
          accountHash: accountHash,
        );
      },
      clearHistoryMany: (ids, {required accountHash}) {
        final provider = activeRift();
        if (provider == null) throw StateError('Rift provider changed');
        return provider.clearCloudWatchHistoryMany(
          ids,
          accountHash: accountHash,
        );
      },
    ),
    onImported: () => ref.read(accountDataRevisionProvider.notifier).bump(),
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_providers.dart';
import '../extensions/extension_manager.dart';
import '../extensions/providers/anime_rift_provider.dart';
import 'anime_rift_account_scope.dart';
import 'anime_rift_cloud_pending.dart';
import 'library_category.dart';
import 'storage_service.dart';

/// A transport with a separately verified HTTP method, body and permissions.
/// Nothing in the shipped app currently implements this interface: recovered
/// endpoint strings alone are not proof of an authorized write contract.
abstract class AnimeRiftVerifiedCloudWriter {
  /// Implementations must bind [accountHash] to the authenticated session
  /// before sending, and reject a switch rather than sending A's edit as B.
  Future<void> write(String accountHash, AnimeRiftCloudPendingChange change);
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
        refresh().catchError((Object error, StackTrace _) {
          _lastError = error;
          // Safe to retry on the next change or lifecycle event. Do not print
          // errors that might contain a signed URL or an account credential.
        }),
      );
    });
  }

  Future<void> _drain() async {
    try {
      do {
        _refreshRequested = false;
        final provider = _activeRift();
        if (provider == null || !await provider.restoreAccountSession()) {
          continue;
        }
        final account = AnimeRiftLocalAccountScope.accountHash;
        if (account == null) continue;

        // A verified writer flushes pending local changes BEFORE pulling,
        // preventing an older server snapshot from overriding a recent edit.
        // Without one, retain every mutation durably and only perform GETs.
        if (_writer != null) await _pushPending(account);
        AnimeRiftCloudPendingJournal.requireAccount(account);
        final result = await provider.importCloudLibrary(_storage);
        AnimeRiftCloudPendingJournal.requireAccount(account);
        if (!_disposed && result.changed > 0) _onImported?.call();
        _lastError = null;
      } while (_refreshRequested && !_disposed);
    } catch (error) {
      _lastError = error;
      rethrow;
    }
  }

  Future<void> _pushPending(String account) async {
    final writer = _writer;
    if (writer == null) return;
    final changes = _journal.pending(account);
    for (final change in changes) {
      AnimeRiftCloudPendingJournal.requireAccount(account);
      if (change.kind == 'rescan') continue;
      await writer.write(account, change);
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
  final coordinator = AnimeRiftAutoSyncCoordinator(
    storage: ref.read(storageServiceProvider),
    activeRift: () {
      final provider = ref.read(activeProviderProvider);
      return provider is AnimeRiftProvider ? provider : null;
    },
    onImported: () => ref.read(accountDataRevisionProvider.notifier).bump(),
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

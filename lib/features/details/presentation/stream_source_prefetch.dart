/// Warms the next episode's source list while the current one is still
/// playing.
///
/// Picking "next" ran the whole chain from cold: ask the provider for the
/// episode's sources, wait, then show the picker. That wait lands at exactly
/// the moment a viewer has decided to keep watching. The list is cheap to
/// fetch and stable for the life of an episode page, so it can be fetched
/// early and handed over instantly.
///
/// Only the *list* is cached, never a resolved playback URL: those are signed
/// and short-lived, and serving a stale one would fail playback rather than
/// speed it up.
library;

import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';

part 'stream_source_prefetch.g.dart';

class StreamSourcePrefetch {
  StreamSourcePrefetch();

  /// Long enough to cover the credits of an episode, short enough that a
  /// provider's own changes are picked up on the next session.
  static const Duration ttl = Duration(minutes: 10);

  /// One episode ahead is all that is ever needed; the cap is for safety.
  static const int maxEntries = 4;

  final Map<String, _Entry> _entries = <String, _Entry>{};

  /// Starts a fetch for [episodeUrl] ahead of anyone asking for it.
  ///
  /// Fire and forget: a warm that errors must not surface anything, because
  /// nobody has asked for these sources yet, and the real request reports its
  /// own failure. [sources] has already arranged for a failure to be
  /// forgotten; catching here only keeps it from going unhandled.
  void warm(AnimeWitcherProvider provider, String episodeUrl) {
    if (episodeUrl.trim().isEmpty) return;
    if (_live(episodeUrl) != null) return;
    unawaited(
      sources(provider, episodeUrl).catchError((_) => const <StreamResult>[]),
    );
  }

  /// The sources for [episodeUrl], from the warm fetch when one is in flight
  /// or already done.
  Future<List<StreamResult>> sources(
    AnimeWitcherProvider provider,
    String episodeUrl,
  ) {
    final live = _live(episodeUrl);
    if (live != null) return live.future;

    final future = provider.loadStreamSources(episodeUrl);
    _entries[episodeUrl] = _Entry(future, DateTime.now().add(ttl));
    _forgetIfItFails(episodeUrl, future);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return future;
  }

  /// Drops a cached fetch that ended in an error.
  ///
  /// Only a result is worth keeping for ten minutes. Keeping a failure that
  /// long turns a moment without a connection into ten minutes without one:
  /// the viewer's obvious answer to "couldn't load the sources" is to tap the
  /// episode again, and that tap was being served the same stored error
  /// without the provider ever being asked, long after the network came back.
  void _forgetIfItFails(String episodeUrl, Future<List<StreamResult>> future) {
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {
          // Only when it is still this future's entry: a later call may have
          // replaced it already, and that one deserves its own life.
          if (identical(_entries[episodeUrl]?.future, future)) {
            _entries.remove(episodeUrl);
          }
        },
      ),
    );
  }

  /// Drops everything — a new anime's episodes have nothing to do with the
  /// last one's.
  void clear() => _entries.clear();

  _Entry? _live(String episodeUrl) {
    final entry = _entries[episodeUrl];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiresAt)) {
      _entries.remove(episodeUrl);
      return null;
    }
    return entry;
  }
}

class _Entry {
  _Entry(this.future, this.expiresAt);

  final Future<List<StreamResult>> future;
  final DateTime expiresAt;
}

@Riverpod(keepAlive: true)
StreamSourcePrefetch streamSourcePrefetch(Ref ref) => StreamSourcePrefetch();

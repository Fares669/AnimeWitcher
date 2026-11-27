import 'dart:async';
import 'dart:collection';

/// Limits speculative downloads so visible images can use the cache manager
/// without waiting behind a whole set of rows.
final class PosterWarmQueue {
  PosterWarmQueue({required this.fetch, required this.isBlocked});

  static const _maxWorkers = 3;
  static const _maxPending = 72;
  // Warming is only an optimization, not the disk cache. Remember recent
  // attempts without pinning every URL ever visited by the process.
  static const _maxRemembered = 1024;

  final Future<void> Function(String url) fetch;
  final bool Function(String url) isBlocked;
  final Queue<String> _pending = Queue<String>();
  final Set<String> _admitted = <String>{};
  final Set<String> _recent = <String>{};
  int _active = 0;

  void enqueue(Iterable<String> urls, {int limit = 24}) {
    var accepted = 0;
    for (final raw in urls) {
      if (accepted >= limit || _pending.length >= _maxPending) break;
      final url = raw.trim();
      if (!url.startsWith('http') ||
          isBlocked(url) ||
          _admitted.contains(url)) {
        continue;
      }
      // Keep hot rows recent; no cache or network work is needed for them.
      if (_recent.remove(url)) {
        _recent.add(url);
        continue;
      }
      _admitted.add(url);
      _pending.addLast(url);
      accepted++;
      if (_active < _maxWorkers) {
        _active++;
        unawaited(_work());
      }
    }
  }

  void _remember(String url) {
    _recent.add(url);
    if (_recent.length > _maxRemembered) {
      _recent.remove(_recent.first);
    }
  }

  Future<void> _work() async {
    try {
      while (_pending.isNotEmpty) {
        final url = _pending.removeFirst();
        // A host can be marked unreachable after admission. Allow this URL to
        // be warmed on a later call if it was never actually attempted.
        if (isBlocked(url)) {
          _admitted.remove(url);
          continue;
        }
        try {
          await fetch(url);
        } catch (_) {
          // The visible card can retry and fall back independently.
        } finally {
          _admitted.remove(url);
          _remember(url);
        }
      }
    } finally {
      _active--;
    }
  }
}

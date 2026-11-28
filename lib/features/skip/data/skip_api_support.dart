import 'skip_service.dart';

/// A per-source, in-memory cache for skip API responses, including empty hits.
class SkipApiCache {
  static const _maxEntries = 500;
  static const _ttl = Duration(hours: 1);

  final _entries =
      <String, ({List<SkipSegment> segments, DateTime expiresAt})>{};

  List<SkipSegment>? lookup(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiresAt)) {
      _entries.remove(key);
      return null;
    }

    // Touch the LRU order without extending the original expiry.
    _entries.remove(key);
    _entries[key] = entry;
    return entry.segments;
  }

  void store(String key, List<SkipSegment> segments) {
    _entries.remove(key);
    _entries[key] = (segments: segments, expiresAt: DateTime.now().add(_ttl));
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

Duration parseSkipRetryAfter(String? header) {
  if (header == null) return const Duration(seconds: 60);
  final seconds = int.tryParse(header.trim());
  if (seconds == null || seconds < 0) return const Duration(seconds: 60);
  if (seconds > 300) return const Duration(minutes: 5);
  return Duration(seconds: seconds);
}

/// The searches you made last, offered back when the field is empty.
///
/// Anime titles are long, transliterated, and easy to mistype — "Buchigire
/// Reijou wa Houfuku wo Chikaimashita" is not something anyone types twice on
/// a phone. The list is kept locally and never leaves the device: it is a
/// convenience, not part of the account.
library;

import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/storage_service.dart';

part 'recent_searches.g.dart';

/// How many are kept. Long enough to hold a browsing session, short enough
/// that the list stays scannable under a search field.
const int recentSearchesMax = 12;

/// The list after searching for [query].
///
/// The newest is first. A repeat of something already in the list moves it to
/// the front rather than appearing twice, matched without regard to case or
/// surrounding spaces — searching "one piece" after "One Piece" is the same
/// search, and two entries that differ only in capitals read as a bug.
///
/// Returns [existing] unchanged when [query] is blank, so an accidental
/// submit of an empty field does not disturb the list.
List<String> withRecentSearch(
  List<String> existing,
  String query, {
  int max = recentSearchesMax,
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return existing;
  if (max <= 0) return const <String>[];

  final folded = trimmed.toLowerCase();
  final kept = <String>[
    trimmed,
    for (final entry in existing)
      if (entry.trim().toLowerCase() != folded) entry,
  ];
  return kept.length <= max ? kept : kept.sublist(0, max);
}

/// The list with [query] taken out, matched the same way it was added.
List<String> withoutRecentSearch(List<String> existing, String query) {
  final folded = query.trim().toLowerCase();
  if (folded.isEmpty) return existing;
  return <String>[
    for (final entry in existing)
      if (entry.trim().toLowerCase() != folded) entry,
  ];
}

/// Reads a stored list, ignoring anything that is not a usable query.
///
/// Storage is shared with older and newer versions of the app, so this takes
/// what it recognises rather than failing on a shape it does not.
List<String> parseRecentSearches(String? raw, {int max = recentSearchesMax}) {
  if (raw == null || raw.trim().isEmpty) return const <String>[];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>[];
    final seen = <String>{};
    final output = <String>[];
    for (final entry in decoded) {
      if (entry is! String) continue;
      final trimmed = entry.trim();
      if (trimmed.isEmpty) continue;
      if (!seen.add(trimmed.toLowerCase())) continue;
      output.add(trimmed);
      if (output.length >= max) break;
    }
    return output;
  } catch (_) {
    return const <String>[];
  }
}

@Riverpod(keepAlive: true)
class RecentSearches extends _$RecentSearches {
  static const String storageKey = 'recent_searches_json';

  StorageService get _storage => ref.read(storageServiceProvider);

  @override
  List<String> build() {
    try {
      return parseRecentSearches(_storage.getString(storageKey));
    } catch (_) {
      // An unopened box on a cold start is not worth failing the screen for.
      return const <String>[];
    }
  }

  /// Records a search that was actually run.
  void record(String query) => _write(withRecentSearch(state, query));

  /// Forgets one entry — the x beside it.
  void remove(String query) => _write(withoutRecentSearch(state, query));

  /// Forgets all of them.
  void clear() => _write(const <String>[]);

  void _write(List<String> next) {
    if (_sameOrder(state, next)) return;
    state = next;
    try {
      _storage.setString(storageKey, jsonEncode(next));
    } catch (_) {
      // The list is a convenience; losing it costs one retyped query.
    }
  }

  static bool _sameOrder(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/entity/multimedia_item.dart';
import '../utils/anime_rift_identity.dart';
import 'anime_rift_account_scope.dart';
import 'library_category.dart';
import 'storage_service.dart';

const animeRiftProviderId = 'com.animerift.provider';

/// Local-only library for a non-native provider. It never touches account sync
/// or the existing native library, and serializes writes per storage instance.
class ProviderLocalLibrary {
  ProviderLocalLibrary(this._storage, String providerId)
    : providerId = providerId.trim(),
      _namespace = AnimeRiftLocalAccountScope.storageNamespace(
        providerId.trim(),
      ) {
    if (this.providerId.isEmpty) throw ArgumentError.value(providerId);
  }

  final StorageService _storage;
  final String providerId;
  final String _namespace;
  static final _queues = Expando<Map<String, Future<void>>>();

  String get storageKey =>
      'provider_library_v1_${sha256.convert(utf8.encode(_namespace))}';

  Map<String, dynamic> _read() {
    final raw = _storage.getString(storageKey);
    if (raw == null) return <String, dynamic>{};
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid local provider library');
    }
    for (final entry in value.values) {
      if (entry is! Map ||
          entry['item'] is! Map ||
          entry['favorite'] is! bool ||
          (entry['category'] != null && entry['category'] is! String)) {
        throw const FormatException('Invalid local provider library entry');
      }
    }
    if (providerId == animeRiftProviderId) {
      final normalized = <String, dynamic>{};
      for (final entry in value.entries) {
        final row = Map<String, dynamic>.from(entry.value as Map);
        final item = Map<String, dynamic>.from(row['item'] as Map);
        final rawUrl = (item['url'] ?? entry.key).toString();
        final id = canonicalAnimeRiftStorageUrl(rawUrl);
        final migrated = MultimediaItem.fromJson(item);
        row['item'] = _riftCatalogSnapshot(migrated, id);
        final previous = normalized[id];
        if (previous is Map) {
          row['favorite'] =
              row['favorite'] == true || previous['favorite'] == true;
          row['category'] ??= previous['category'];
        }
        normalized[id] = row;
      }
      return normalized;
    }
    return value;
  }

  String _id(String value) => providerId == animeRiftProviderId
      ? canonicalAnimeRiftStorageUrl(value)
      : value.trim();

  bool isFavorite(String id) => (_read()[_id(id)] as Map?)?['favorite'] == true;

  MultimediaItem? item(String id) {
    final row = _read()[_id(id)] as Map?;
    if (row == null) return null;
    return MultimediaItem.fromJson(
      Map<String, dynamic>.from(row['item'] as Map),
    );
  }

  Future<void> clearCategory(String id) async {
    final existing = item(id);
    if (existing != null) await setCategory(existing, null);
  }

  LibraryCategory? category(String id) {
    final value = (_read()[_id(id)] as Map?)?['category'];
    if (value is! String) return null;
    final result = LibraryCategory.fromStorageKey(value);
    return result.isPrimary ? result : null;
  }

  List<MultimediaItem> items(LibraryCategory category) {
    return _read().values
        .where((entry) {
          final row = entry as Map;
          return category == LibraryCategory.favorite
              ? row['favorite'] == true
              : row['category'] == category.storageKey;
        })
        .map((entry) {
          final row = entry as Map;
          return MultimediaItem.fromJson(
            Map<String, dynamic>.from(row['item'] as Map),
          );
        })
        .toList(growable: false);
  }

  List<MultimediaItem> allItems() => _read().values
      .map((entry) {
        final row = entry as Map;
        return MultimediaItem.fromJson(
          Map<String, dynamic>.from(row['item'] as Map),
        );
      })
      .toList(growable: false);

  Future<void> remove(String id) => _enqueue(() {
    final entries = _read();
    entries.remove(_id(id));
    return entries;
  });

  Future<void> setFavorite(MultimediaItem item, bool favorite) =>
      _write(item, favorite: favorite);

  Future<void> setCategory(MultimediaItem item, LibraryCategory? category) {
    if (category == LibraryCategory.favorite) {
      throw ArgumentError.value(category, 'category');
    }
    return _write(item, category: category, changeCategory: true);
  }

  Future<void> _write(
    MultimediaItem item, {
    bool? favorite,
    LibraryCategory? category,
    bool changeCategory = false,
  }) {
    final id = _id(item.url);
    if (id.isEmpty) throw ArgumentError.value(item.url, 'item.url');
    return _enqueue(() {
      final entries = _read();
      final existing = entries[id] as Map?;
      final savedFavorite = favorite ?? (existing?['favorite'] == true);
      final savedCategory = changeCategory
          ? category?.storageKey
          : existing?['category'];
      if (!savedFavorite && savedCategory == null) {
        entries.remove(id);
      } else {
        entries[id] = <String, dynamic>{
          'item': providerId == animeRiftProviderId
              ? _riftCatalogSnapshot(item, id)
              : item.copyWith(provider: providerId).toJson(),
          'favorite': savedFavorite,
          'category': savedCategory,
        };
      }
      return entries;
    });
  }

  Future<void> _enqueue(Map<String, dynamic> Function() update) {
    final queues = _queues[_storage] ??= <String, Future<void>>{};
    final previous = queues[storageKey] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      await _storage.setString(storageKey, jsonEncode(update()));
    });
    queues[storageKey] = next;
    return next;
  }

  Map<String, dynamic> _riftCatalogSnapshot(MultimediaItem item, String id) => {
    'title': item.title,
    'url': id,
    'posterUrl': item.posterUrl,
    'fullPosterUrl': item.fullPosterUrl,
    'bannerUrl': item.bannerUrl,
    'logoUrl': item.logoUrl,
    'description': item.description,
    'type': item.contentType.name,
    'provider': providerId,
    'year': item.year,
    'score': item.score,
    'duration': item.duration,
    'status': item.status.name,
    'tags': item.tags,
    'contentRating': item.contentRating,
    'isAdult': item.isAdult,
    'tmdbId': item.tmdbId,
    'imdbId': item.imdbId,
    'source': item.source,
    'episodeBadge': item.episodeBadge,
    'catalogType': item.catalogType,
    'publishedAt': item.publishedAt?.millisecondsSinceEpoch,
    'isDubbed': item.isDubbed,
  };
}

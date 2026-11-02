import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/entity/multimedia_item.dart';
import 'library_category.dart';
import 'storage_service.dart';

const animeRiftProviderId = 'com.animerift.provider';

/// Local-only library for a non-native provider. It never touches account sync
/// or the existing native library, and serializes writes per storage instance.
class ProviderLocalLibrary {
  ProviderLocalLibrary(this._storage, String providerId)
    : providerId = providerId.trim() {
    if (this.providerId.isEmpty) throw ArgumentError.value(providerId);
  }

  final StorageService _storage;
  final String providerId;
  static final _queues = Expando<Map<String, Future<void>>>();

  String get storageKey =>
      'provider_library_v1_${sha256.convert(utf8.encode(providerId))}';

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
    return value;
  }

  bool isFavorite(String id) => (_read()[id] as Map?)?['favorite'] == true;

  MultimediaItem? item(String id) {
    final row = _read()[id] as Map?;
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
    final value = (_read()[id] as Map?)?['category'];
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
    final id = item.url.trim();
    if (id.isEmpty) throw ArgumentError.value(item.url, 'item.url');
    final queues = _queues[_storage] ??= <String, Future<void>>{};
    final previous = queues[storageKey] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
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
          'item': item.copyWith(provider: providerId).toJson(),
          'favorite': savedFavorite,
          'category': savedCategory,
        };
      }
      await _storage.setString(storageKey, jsonEncode(entries));
    });
    queues[storageKey] = next;
    return next;
  }
}

import 'package:crypto/crypto.dart';

import '../network/poster_cache.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

import 'dart:io';

import 'download_persistence_worker.dart';
import 'scoped_cache_files.dart';

import '../domain/entity/multimedia_item.dart';
import '../services/download_concurrency.dart';
import '../services/download_parallel.dart';
import '../utils/safe_uri.dart';

part 'storage_service.g.dart';

@Riverpod(keepAlive: true)
StorageService storageService(Ref ref) {
  throw UnimplementedError('StorageService must be initialized');
}

typedef _StoredLibraryCard = ({
  Map<dynamic, dynamic> row,
  String url,
  String title,
  int updatedAt,
});

/// A last-watched date for an already known local history row.
typedef RecentHistoryUpdate = ({
  String url,
  String? episodeUrl,
  int timestamp,
  int position,
});

class StorageService {
  StorageService({DownloadPersistenceWorker? downloadPersistenceWorker})
    : _downloadPersistenceWorker = downloadPersistenceWorker == null
          ? null
          : Future.value(downloadPersistenceWorker);

  Future<DownloadPersistenceWorker>? _downloadPersistenceWorker;

  Future<dynamic> _downloadMetadata(
    String operation,
    List<Object?> arguments,
  ) async {
    final worker = await (_downloadPersistenceWorker ??=
        DownloadPersistenceWorker.application());
    return worker.run(operation, <Object?>[kDownloadMetadataBox, ...arguments]);
  }

  late Box<dynamic> _libraryBox;
  late Box<dynamic> _settingsBox;
  late Box<dynamic> _extensionsBox;
  late Box<dynamic> _historyBox;
  late Box<dynamic> _continueWatchingBox;

  static const String kLibraryBox = 'library_box';
  static const String kSettingsBox = 'settings_box';
  static const String kExtensionsBox = 'extension_data_box';
  static const String kDownloadMetadataBox = 'download_metadata_box';
  static const String kContinueWatchingBox = 'continue_watching_box';

  Future<void> init() async {
    final supportDir = await getApplicationSupportDirectory();
    Hive.init(supportDir.path);

    _libraryBox = await _safeOpenBox(kLibraryBox);
    _settingsBox = await _safeOpenBox(kSettingsBox);
    _extensionsBox = await _safeOpenBox(kExtensionsBox);
    await _downloadMetadata('hive.safeOpen', []);
    await initHistory();
    _continueWatchingBox = await _safeOpenBox(kContinueWatchingBox);
    await _migrateContinueWatchingStorage();
  }

  Future<Box<dynamic>> _safeOpenBox(String boxName) async {
    try {
      return await Hive.openBox<dynamic>(boxName);
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          "Error opening Hive box '$boxName': $e. Attempting recovery before deleting...",
        );
      }

      // Attempt to salvage any readable entries before wiping the box.
      final Map<dynamic, dynamic> salvaged = {};
      try {
        final recoveryBox = await Hive.openBox<dynamic>(
          boxName,
          crashRecovery: true,
        );
        for (var i = 0; i < recoveryBox.length; i++) {
          final key = recoveryBox.keyAt(i);
          salvaged[key] = recoveryBox.get(key);
        }
        await recoveryBox.close();
      } catch (_) {
        // Box is unreadable even with crash recovery — salvaged stays empty.
      }

      try {
        await Hive.deleteBoxFromDisk(boxName);
      } catch (_) {}

      final fresh = await Hive.openBox<dynamic>(boxName);

      // Re-insert recovered entries.
      if (salvaged.isNotEmpty) {
        await fresh.putAll(salvaged);
        if (kDebugMode) {
          debugPrint(
            "Hive box '$boxName': recovered ${salvaged.length} entries after corruption.",
          );
        }
      }

      return fresh;
    }
  }

  /// Helper to ensure keys do not exceed Hive's 255 char limit.
  /// Generates a stable hash for long URLs.
  String _getKey(String url) {
    if (url.length <= 250) return url;
    return md5.convert(utf8.encode(url)).toString();
  }

  String _canonicalMediaUrl(String rawUrl) {
    final value = rawUrl.trim();
    final uri = safeTryParseUri(value);
    if (uri == null) return value;
    final host = uri.host.toLowerCase();
    if ((host == 'animewitcher.com' || host == 'www.animewitcher.com') &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments.first == 'watch') {
      final animeId = uri.pathSegments[1].trim();
      if (animeId.isEmpty) return value;
      return Uri(
        scheme: 'https',
        host: 'animewitcher.com',
        pathSegments: <String>['watch', animeId],
      ).toString();
    }
    return value;
  }

  int _historyTimestamp(Map<dynamic, dynamic> raw) {
    final value = raw['timestamp'];
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool _historyEntryMatchesUrl(Map<dynamic, dynamic> raw, String canonicalUrl) {
    final storedUrl = (raw['url'] ?? '').toString();
    return storedUrl.isNotEmpty &&
        _canonicalMediaUrl(storedUrl) == canonicalUrl;
  }

  Map<dynamic, dynamic>? _latestHistoryMainEntry(String canonicalUrl) {
    Map<dynamic, dynamic>? latest;
    var latestTimestamp = -1;
    for (var i = 0; i < _historyBox.length; i++) {
      final key = _historyBox.keyAt(i);
      if (key is String && key.startsWith('EP_')) continue;
      final raw = _historyBox.getAt(i);
      if (raw is! Map || !_historyEntryMatchesUrl(raw, canonicalUrl)) {
        continue;
      }
      final timestamp = _historyTimestamp(raw);
      if (latest == null || timestamp > latestTimestamp) {
        latest = Map<dynamic, dynamic>.from(raw);
        latestTimestamp = timestamp;
      }
    }
    return latest;
  }

  // --- Library (AnimeWitcher lists) ---

  static const String _defaultLibraryCategory = 'favorite';

  String _normalizeLibraryCategory(dynamic raw) {
    final value = (raw ?? '').toString().trim();
    switch (value) {
      case 'watching':
        return 'watching';
      case 'completed':
        return 'completed';
      case 'on_Hold':
      case 'onHold':
      case 'continueLater':
      case 'continue_later':
        return 'onHold';
      case 'no_watching':
      case 'noWatching':
        return 'noWatching';
      case 'pin':
      case 'pinned':
        return 'pinned';
      case 'favorite':
      case 'favorites':
      case 'fav':
        return 'favorite';
      default:
        return _defaultLibraryCategory;
    }
  }

  String? _normalizePrimaryLibraryCategory(dynamic raw) {
    final value = (raw ?? '').toString().trim();
    switch (value) {
      case 'watching':
        return 'watching';
      case 'completed':
        return 'completed';
      case 'on_Hold':
      case 'onHold':
      case 'continueLater':
      case 'continue_later':
        return 'onHold';
      case 'no_watching':
      case 'noWatching':
        return 'noWatching';
      case 'pin':
      case 'pinned':
        return 'pinned';
      case 'favorite':
      case 'favorites':
      case 'fav':
      case '':
        return null;
      default:
        return null;
    }
  }

  dynamic _rawLibraryCategory(Map<dynamic, dynamic> raw) =>
      raw['libraryCategory'] ?? raw['library_category'] ?? raw['category'];

  String? _storedLibraryCategory(Map<dynamic, dynamic> raw) {
    return _normalizePrimaryLibraryCategory(_rawLibraryCategory(raw));
  }

  bool _storedLibraryFavorite(Map<dynamic, dynamic> raw) {
    final explicit = raw['isFavorite'] ?? raw['is_favorite'] ?? raw['favorite'];
    if (explicit is bool) return explicit;
    if (explicit is num) return explicit != 0;
    if (explicit != null) {
      final value = explicit.toString().trim().toLowerCase();
      if (value == 'true' || value == '1') return true;
      if (value == 'false' || value == '0') return false;
    }

    final legacyCategory = _rawLibraryCategory(raw);
    if (legacyCategory == null) {
      // Bookmarks created before list categories existed were favorites.
      return true;
    }
    return _normalizeLibraryCategory(legacyCategory) == 'favorite';
  }

  Future<void> addToLibrary(
    MultimediaItem item, {
    String? category,
    bool replaceCategory = false,
    bool? favorite,
    int? updatedAt,
    String? syncedAccountUid,
    int? syncedAt,
  }) async {
    final canonicalUrl = _canonicalMediaUrl(item.url);
    Map<dynamic, dynamic>? previousEntry;
    final staleKeys = <dynamic>[];
    for (var i = 0; i < _libraryBox.length; i++) {
      final key = _libraryBox.keyAt(i);
      final raw = _libraryBox.get(key);
      if (raw is! Map) continue;
      final storedUrl = (raw['url'] as String?) ?? '';
      if (_canonicalMediaUrl(storedUrl) == canonicalUrl) {
        previousEntry ??= Map<dynamic, dynamic>.from(raw);
        if (key != _getKey(canonicalUrl)) {
          staleKeys.add(key);
        }
      }
    }
    for (final key in staleKeys) {
      await _libraryBox.delete(key);
    }

    final previousCategory = previousEntry == null
        ? null
        : _storedLibraryCategory(previousEntry);
    final previousFavorite = previousEntry == null
        ? false
        : _storedLibraryFavorite(previousEntry);
    final normalizedRequested = category == null
        ? null
        : _normalizeLibraryCategory(category);
    final legacyFavoriteRequest = normalizedRequested == 'favorite';
    final effectiveCategory = replaceCategory
        ? _normalizePrimaryLibraryCategory(category)
        : category == null || legacyFavoriteRequest
        ? previousCategory
        : _normalizePrimaryLibraryCategory(category);
    final effectiveFavorite =
        favorite ??
        (legacyFavoriteRequest
            ? true
            : previousEntry == null && category == null
            ? true
            : previousFavorite);

    final key = _getKey(canonicalUrl);
    if (effectiveCategory == null && !effectiveFavorite) {
      await _libraryBox.delete(key);
      return;
    }

    await _libraryBox.put(key, {
      'title': item.title,
      'url': canonicalUrl,
      'posterUrl': item.posterUrl,
      'bannerUrl': item.bannerUrl,
      'description': item.description,
      'type': item.contentType.name,
      'catalogType': item.catalogType,
      'year': item.year,
      'isDubbed': item.isDubbed,
      'provider': item.provider,
      'status': item.status.name,
      'libraryCategory': effectiveCategory,
      'isFavorite': effectiveFavorite,
      'updatedAt': updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      if (syncedAccountUid != null)
        'animeWitcherSyncedUid': syncedAccountUid
      else if (previousEntry?['animeWitcherSyncedUid'] != null)
        'animeWitcherSyncedUid': previousEntry!['animeWitcherSyncedUid'],
      if (syncedAt != null)
        'animeWitcherSyncedAt': syncedAt
      else if (previousEntry?['animeWitcherSyncedAt'] != null)
        'animeWitcherSyncedAt': previousEntry!['animeWitcherSyncedAt'],
    });
  }

  Future<void> setLibraryItemCategory(String url, String? category) async {
    final canonicalUrl = _canonicalMediaUrl(url);
    final normalizedCategory = _normalizePrimaryLibraryCategory(category);
    for (var i = 0; i < _libraryBox.length; i++) {
      final key = _libraryBox.keyAt(i);
      final raw = _libraryBox.get(key);
      if (raw is! Map) continue;
      final map = Map<dynamic, dynamic>.from(raw);
      if (_canonicalMediaUrl((map['url'] as String?) ?? '') != canonicalUrl) {
        continue;
      }
      if (normalizedCategory == null && !_storedLibraryFavorite(map)) {
        await _libraryBox.delete(key);
        return;
      }
      map['libraryCategory'] = normalizedCategory;
      map['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
      await _libraryBox.put(key, map);
      return;
    }
  }

  int getLibraryItemUpdatedAt(String url) {
    return _libraryMetadataInt(url, 'updatedAt');
  }

  int getLibraryItemSyncedAt(String url) {
    return _libraryMetadataInt(url, 'animeWitcherSyncedAt');
  }

  String? getLibraryItemSyncedAccountUid(String url) {
    final value = _libraryMetadata(
      url,
      'animeWitcherSyncedUid',
    )?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> markLibraryItemSynced(
    String url, {
    required String accountUid,
    required int syncedAt,
  }) async {
    final canonicalUrl = _canonicalMediaUrl(url);
    for (var i = 0; i < _libraryBox.length; i++) {
      final key = _libraryBox.keyAt(i);
      final raw = _libraryBox.get(key);
      if (raw is! Map) continue;
      final map = Map<dynamic, dynamic>.from(raw);
      if (_canonicalMediaUrl((map['url'] as String?) ?? '') != canonicalUrl) {
        continue;
      }
      map['animeWitcherSyncedUid'] = accountUid;
      map['animeWitcherSyncedAt'] = syncedAt;
      await _libraryBox.put(key, map);
      return;
    }
  }

  final _libraryRowUrls = Expando<({String source, String canonical})>();

  Map<dynamic, dynamic>? _firstLibraryRow(String canonicalUrl) {
    // Hive's values iterator is in the same key order as getAt(). Iterate
    // current rows, not cached metadata: local/cloud writes take effect now.
    for (final raw in _libraryBox.values) {
      if (raw is! Map) continue;
      final source = (raw['url'] as String?) ?? '';
      final cached = _libraryRowUrls[raw];
      final String canonical;
      if (cached != null && cached.source == source) {
        canonical = cached.canonical;
      } else {
        canonical = _canonicalMediaUrl(source);
        // Weakly associate only pure URL normalization with the live row.
        _libraryRowUrls[raw] = (source: source, canonical: canonical);
      }
      if (canonical == canonicalUrl) return raw;
    }
    return null;
  }

  dynamic _libraryMetadata(String url, String field) =>
      _firstLibraryRow(_canonicalMediaUrl(url))?[field];

  int _libraryMetadataInt(String url, String field) {
    final raw = _libraryMetadata(url, field);
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  Future<void> removeFromLibrary(String url) async {
    final canonicalUrl = _canonicalMediaUrl(url);
    final keys = <dynamic>[];
    for (var i = 0; i < _libraryBox.length; i++) {
      final key = _libraryBox.keyAt(i);
      final raw = _libraryBox.get(key);
      if (raw is Map &&
          _canonicalMediaUrl((raw['url'] as String?) ?? '') == canonicalUrl) {
        keys.add(key);
      }
    }
    for (final key in keys) {
      await _libraryBox.delete(key);
    }
  }

  bool isInLibrary(String url) {
    final canonicalUrl = _canonicalMediaUrl(url);
    return _libraryBox.containsKey(_getKey(canonicalUrl)) ||
        _firstLibraryRow(canonicalUrl) != null;
  }

  bool isLibraryItemFavorite(String url) {
    final raw = _firstLibraryRow(_canonicalMediaUrl(url));
    return raw != null && _storedLibraryFavorite(raw);
  }

  String? getLibraryItemCategory(String url) {
    final raw = _firstLibraryRow(_canonicalMediaUrl(url));
    return raw == null ? null : _storedLibraryCategory(raw);
  }

  List<MultimediaItem> getLibraryItems({String? category}) => [
    for (final card in _orderedLibraryRows(category))
      _hydrateLibraryCard(card, _storedLibraryContentType(card.row)),
  ];

  /// Page of the local shelf in the same order as [getLibraryItems], plus
  /// the full unpaginated count for this media kind. Off-page rows remain raw
  /// Hive metadata, not transient [MultimediaItem]s.
  ({List<MultimediaItem> items, int total}) getLocalLibraryShelf({
    required String category,
    required bool manga,
    required int limit,
  }) {
    final items = <MultimediaItem>[];
    var total = 0;
    for (final card in _orderedLibraryRows(category)) {
      final type = _storedLibraryContentType(card.row);
      if ((type == MultimediaContentType.manga) != manga) continue;
      total++;
      if (items.length < limit) items.add(_hydrateLibraryCard(card, type));
    }
    return (items: items, total: total);
  }

  List<_StoredLibraryCard> _orderedLibraryRows(String? category) {
    final entries = <_StoredLibraryCard>[];
    final seen = <String>{};
    final normalizedFilter = category == null
        ? null
        : _normalizeLibraryCategory(category);
    for (final raw in _libraryBox.values) {
      if (raw is! Map) continue;
      if (normalizedFilter == 'favorite') {
        if (!_storedLibraryFavorite(raw)) continue;
      } else if (normalizedFilter != null &&
          _storedLibraryCategory(raw) != normalizedFilter) {
        continue;
      }
      final url = _canonicalMediaUrl((raw['url'] as String?) ?? '');
      // The first canonical row in Hive order wins within a category even
      // when it belongs to another media kind or has an older timestamp.
      if (url.isEmpty || !seen.add(url)) continue;
      entries.add((
        row: raw,
        url: url,
        title: (raw['title'] as String?) ?? '',
        updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? 0,
      ));
    }
    entries.sort((a, b) {
      final cmp = b.updatedAt.compareTo(a.updatedAt);
      if (cmp != 0) return cmp;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return entries;
  }

  MultimediaContentType _storedLibraryContentType(Map<dynamic, dynamic> row) =>
      MultimediaItem.parseContentType(
        (row['type'] as String?) ?? (row['contentType'] as String?),
      );

  MultimediaItem _hydrateLibraryCard(
    _StoredLibraryCard card,
    MultimediaContentType type,
  ) {
    final row = card.row;
    final status = (row['status'] ?? '').toString();
    return MultimediaItem(
      title: card.title,
      url: card.url,
      posterUrl: (row['posterUrl'] as String?) ?? '',
      bannerUrl: row['bannerUrl'] as String?,
      description: row['description'] as String?,
      contentType: type,
      catalogType: row['catalogType'] as String?,
      year: (row['year'] as num?)?.toInt(),
      isDubbed: row['isDubbed'] == true,
      provider: row['provider'] as String?,
      status: status == 'completed'
          ? ShowStatus.completed
          : status == 'upcoming'
          ? ShowStatus.upcoming
          : ShowStatus.ongoing,
    );
  }

  /// Number of unique local cards by persisted shelf, without hydrating cards.
  Map<String, ({int anime, int manga})> getLocalLibraryCounts() {
    final counts = <String, ({int anime, int manga})>{};
    final seenByCategory = <String, Set<String>>{};
    for (final raw in _libraryBox.values) {
      if (raw is! Map) continue;
      final category = _storedLibraryCategory(raw);
      final favorite = _storedLibraryFavorite(raw);
      if (category == null && !favorite) continue;
      final url = _canonicalMediaUrl((raw['url'] as String?) ?? '');
      if (url.isEmpty) continue;
      // getLibraryItems filters by shelf before deduplicating, and the
      // caller splits kinds after. A cross-kind duplicate keeps the first
      // row for that shelf, even when another shelf has a different winner.
      final newPrimary =
          category != null && (seenByCategory[category] ??= {}).add(url);
      final newFavorite =
          favorite && (seenByCategory['favorite'] ??= {}).add(url);
      if (!newPrimary && !newFavorite) continue;
      final isManga =
          _storedLibraryContentType(raw) == MultimediaContentType.manga;
      void add(String key) {
        final count = counts[key] ?? (anime: 0, manga: 0);
        counts[key] = isManga
            ? (anime: count.anime, manga: count.manga + 1)
            : (anime: count.anime + 1, manga: count.manga);
      }

      if (newPrimary) add(category);
      if (newFavorite) add('favorite');
    }
    return counts;
  }

  Future<void> setSelectedLibraryCategory(String category) async {
    await _settingsBox.put(
      'library_selected_category',
      _normalizeLibraryCategory(category),
    );
  }

  String getSelectedLibraryCategory() {
    return _normalizeLibraryCategory(
      _settingsBox.get(
        'library_selected_category',
        defaultValue: _defaultLibraryCategory,
      ),
    );
  }

  String _libraryCountsCacheKey({
    required String providerKey,
    required String accountKey,
    required String mediaKindKey,
  }) =>
      'library_cached_counts_v1:$providerKey:'
      '${Uri.encodeComponent(accountKey)}:$mediaKindKey';

  Map<String, int> getCachedLibraryCounts({
    required String providerKey,
    required String accountKey,
    required String mediaKindKey,
  }) {
    final raw = getString(
      _libraryCountsCacheKey(
        providerKey: providerKey,
        accountKey: accountKey,
        mediaKindKey: mediaKindKey,
      ),
    );
    if (raw == null || raw.isEmpty) return const <String, int>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, int>{};
      final result = <String, int>{};
      for (final entry in decoded.entries) {
        final key = _normalizeLibraryCategory(entry.key);
        final value = entry.value;
        final count = value is num
            ? value.toInt()
            : int.tryParse(value?.toString() ?? '');
        if (count != null && count >= 0) {
          result[key] = count;
        }
      }
      return result;
    } catch (_) {
      return const <String, int>{};
    }
  }

  Future<void> setCachedLibraryCounts({
    required String providerKey,
    required String accountKey,
    required String mediaKindKey,
    required Map<String, int> counts,
    bool merge = true,
  }) async {
    final current = merge
        ? Map<String, int>.from(
            getCachedLibraryCounts(
              providerKey: providerKey,
              accountKey: accountKey,
              mediaKindKey: mediaKindKey,
            ),
          )
        : <String, int>{};
    for (final entry in counts.entries) {
      if (entry.value >= 0) {
        current[_normalizeLibraryCategory(entry.key)] = entry.value;
      }
    }
    await setString(
      _libraryCountsCacheKey(
        providerKey: providerKey,
        accountKey: accountKey,
        mediaKindKey: mediaKindKey,
      ),
      jsonEncode(current),
    );
  }

  // --- Settings ---

  Future<void> saveThemeMode(String mode) async {
    await _settingsBox.put('theme_mode', mode);
  }

  String? getThemeMode() {
    return _settingsBox.get('theme_mode') as String?;
  }

  // --- Sidebar State ---
  Future<void> setSidebarExpanded(bool expanded) async {
    await _settingsBox.put('sidebar_expanded', expanded);
  }

  bool? getSidebarExpanded() {
    return _settingsBox.get('sidebar_expanded') as bool?;
  }

  Future<void> setDefaultHomeScreen(String path) async {
    await _settingsBox.put('default_home_screen', path);
  }

  String getDefaultHomeScreen() {
    return _settingsBox.get('default_home_screen', defaultValue: '/home')
        as String;
  }

  Future<void> setTaskbarOrder(List<String> order) async {
    await _settingsBox.put('taskbar_order', List<String>.from(order));
  }

  List<String> getTaskbarOrder() {
    final value = _settingsBox.get('taskbar_order');
    if (value is! List) return const <String>[];
    return value.map((item) => item.toString()).toList(growable: false);
  }

  Future<void> setHiddenTaskbarItems(Set<String> hidden) async {
    await _settingsBox.put(
      'hidden_taskbar_items',
      hidden.toList(growable: false),
    );
  }

  Set<String> getHiddenTaskbarItems() {
    final value = _settingsBox.get('hidden_taskbar_items');
    final hidden = value is List
        ? value.map((item) => item.toString()).toSet()
        : <String>{};
    // The manga tab came after these were first saved. Until the order saved
    // beside them knows it, it stays hidden: showing it is the viewer's call,
    // made in the taskbar settings, which then save both lists together.
    if (!getTaskbarOrder().contains('manga')) hidden.add('manga');
    return hidden;
  }

  Future<void> setDevLoadAssets(bool enabled) async {
    await _settingsBox.put('dev_load_assets', enabled);
  }

  bool getDevLoadAssets() {
    return _settingsBox.get('dev_load_assets', defaultValue: false) as bool;
  }

  // --- Active Provider ---

  Future<void> setActiveProviderId(String? id) async {
    await _settingsBox.put('active_provider_id', id ?? '__NONE__');
  }

  String? getActiveProviderId() {
    final id = _settingsBox.get('active_provider_id') as String?;
    if (id == null || id == '__NONE__') return null;
    return id;
  }

  // --- Home Category Persistence ---

  Future<void> setHomeCategory(String? category) async {
    await _settingsBox.put('home_category_filter', category);
  }

  String? getHomeCategory() {
    return _settingsBox.get('home_category_filter') as String?;
  }

  // --- Anime metadata source toggles ---

  static const String _kEpisodeImagesFromAniZip =
      'anime_source_episode_images_anizip';

  Future<void> setEpisodeImagesFromAniZipEnabled(bool enabled) async {
    await _settingsBox.put(_kEpisodeImagesFromAniZip, enabled);
  }

  bool isEpisodeImagesFromAniZipEnabled() {
    return (_settingsBox.get(_kEpisodeImagesFromAniZip, defaultValue: true)
            as bool?) ??
        true;
  }

  static const String _kHighQualityPosters =
      'anime_source_high_quality_posters';

  Future<void> setHighQualityPostersEnabled(bool enabled) async {
    await _settingsBox.put(_kHighQualityPosters, enabled);
  }

  bool isHighQualityPostersEnabled() {
    return (_settingsBox.get(_kHighQualityPosters, defaultValue: true)
            as bool?) ??
        true;
  }

  // --- Download queue ---

  Future<void> setDownloadDiagnosticLog(bool value) async {
    await _settingsBox.put('download_diagnostic_log', value);
  }

  bool getDownloadDiagnosticLog() =>
      _settingsBox.get('download_diagnostic_log') == true;

  Future<void> setDownloadConcurrency(int value) async {
    await _settingsBox.put(
      kDownloadConcurrencyStorageKey,
      clampDownloadConcurrency(value),
    );
  }

  int getDownloadConcurrency() {
    return parseDownloadConcurrency(
      _settingsBox.get(kDownloadConcurrencyStorageKey),
    );
  }

  Future<void> setDownloadParallelParts(int value) async {
    await _settingsBox.put(
      kDownloadPartsSettingKey,
      normalizeDownloadPartPreference(value),
    );
  }

  int getDownloadParallelParts() => normalizeDownloadPartPreference(
    _settingsBox.get(kDownloadPartsSettingKey),
  );

  Future<void> setDownloadNotificationPrefs(
    DownloadNotificationPrefs prefs,
  ) async {
    await _settingsBox.put(kDownloadNotificationSettingsKey, prefs.toJson());
  }

  DownloadNotificationPrefs getDownloadNotificationPrefs() {
    return parseDownloadNotificationPrefs(
      _settingsBox.get(kDownloadNotificationSettingsKey),
    );
  }

  @visibleForTesting
  void debugBindSettingsBox(Box<dynamic> box) {
    _settingsBox = box;
  }

  // --- Custom Plugin Overrides ---

  Future<void> setCustomBaseUrl(String packageName, String? url) async {
    final key = 'custom_base_url_$packageName';
    if (url == null) {
      await _settingsBox.delete(key);
    } else {
      await _settingsBox.put(key, url);
    }
  }

  String? getCustomBaseUrl(String packageName) {
    return _settingsBox.get('custom_base_url_$packageName') as String?;
  }

  // --- Language ---
  Future<void> setLanguage(String lang) async {
    await _settingsBox.put('language', lang);
  }

  String getLanguage() {
    return _settingsBox.get('language', defaultValue: 'ar') as String;
  }

  Future<void> setExploreLanguage(String lang) async {
    await _settingsBox.put('explore_language', lang);
  }

  String getExploreLanguage() {
    return _settingsBox.get('explore_language', defaultValue: 'en-US')
        as String;
  }

  // --- Window Settings ---
  Future<void> setAlwaysOnTop(bool enabled) async {
    await _settingsBox.put('always_on_top', enabled);
  }

  bool isAlwaysOnTop() {
    return (_settingsBox.get('always_on_top', defaultValue: false) as bool?) ??
        false;
  }

  // --- Artwork hosts ---
  // Remembers whether the MyAnimeList image CDN answered last time it was
  // probed, so the first frame can pick reachable artwork without waiting.
  Future<void> setMalArtworkUnreachable(bool unreachable) {
    return _settingsBox.putAll(<String, Object>{
      'mal_artwork_unreachable': unreachable,
      'mal_artwork_probed_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  bool isMalArtworkUnreachable() {
    return (_settingsBox.get('mal_artwork_unreachable', defaultValue: false)
            as bool?) ??
        false;
  }

  DateTime? malArtworkProbedAt() {
    final raw = _settingsBox.get('mal_artwork_probed_at');
    if (raw is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(raw);
  }

  // Posters resolved from AniZip/Kitsu for titles whose catalog artwork
  // cannot be reached. Persisted so a restart paints them immediately
  // instead of re-asking for every card.
  /// Off by default; only a viewer whose network blocks the artwork host
  /// needs the app to look anywhere else.
  Future<void> setArtworkFallbackEnabled(bool enabled) async {
    await _settingsBox.put('artwork_fallback_enabled', enabled);
  }

  bool isArtworkFallbackEnabled() {
    final value = _settingsBox.get('artwork_fallback_enabled');
    return value is bool ? value : false;
  }

  Future<void> setFallbackPosters(Map<String, String> value) async {
    await _settingsBox.put('artwork_fallback_posters_json', jsonEncode(value));
  }

  Map<String, String> getFallbackPosters() {
    try {
      final raw = _settingsBox.get('artwork_fallback_posters_json');
      if (raw is! String || raw.trim().isEmpty) return <String, String>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return <String, String>{};
    }
  }

  // --- Player Settings ---
  Future<void> setPlayerSetting(String key, dynamic value) async {
    await _settingsBox.put(key, value);
  }

  T? getPlayerSetting<T>(String key, {T? defaultValue}) {
    return _settingsBox.get(key, defaultValue: defaultValue) as T?;
  }

  // --- General Key-Value ---
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      await _settingsBox.delete(key);
    } else {
      await _settingsBox.put(key, value);
    }
  }

  String? getString(String key) {
    return _settingsBox.get(key) as String?;
  }

  Future<void> remove(String key) async {
    await _settingsBox.delete(key);
  }

  // --- Watch History ---

  static const String kHistoryBox = 'history_box';
  // Box late initialization is handled in init()
  List<Map<String, dynamic>>? _cachedHistory;
  bool _historyCacheDirty = true;

  Future<void> initHistory() async {
    _historyBox = await _safeOpenBox(kHistoryBox);
  }

  static const String _kContinueWatchingMigrationV1 =
      'continue_watching_storage_v1_migrated';
  List<Map<String, dynamic>>? _cachedContinueWatching;
  bool _continueWatchingCacheDirty = true;

  Future<void> _migrateContinueWatchingStorage() async {
    if (_settingsBox.get(_kContinueWatchingMigrationV1, defaultValue: false) ==
        true) {
      return;
    }

    // Before the two concepts were separated, the home Continue Watching row
    // read directly from history_box. Copy the old entries once so upgrades do
    // not lose the user's resume list. Future history-only entries never enter
    // this box.
    if (_continueWatchingBox.isEmpty) {
      final migrated = <dynamic, dynamic>{};
      for (var i = 0; i < _historyBox.length; i++) {
        final key = _historyBox.keyAt(i);
        final value = _historyBox.get(key);
        if (key != null && value is Map) {
          migrated[key] = Map<dynamic, dynamic>.from(value);
        }
      }
      if (migrated.isNotEmpty) {
        await _continueWatchingBox.putAll(migrated);
      }
    }
    await _settingsBox.put(_kContinueWatchingMigrationV1, true);
    _continueWatchingCacheDirty = true;
  }

  Future<void> saveProgress(
    MultimediaItem item,
    int positionMillis,
    int durationMillis, {
    String? lastStreamUrl,
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
    int? timestamp,
    String? syncedAccountUid,
    int? syncedAt,
  }) async {
    final canonicalUrl = _canonicalMediaUrl(item.url);
    final canonicalKey = _getKey(canonicalUrl);
    final existing = _historyBox.get(canonicalKey);
    final legacy = existing is Map
        ? null
        : _latestHistoryMainEntry(canonicalUrl);
    final previous = existing is Map
        ? Map<dynamic, dynamic>.from(existing)
        : legacy ?? const <dynamic, dynamic>{};
    final entry = {
      'title': item.title,
      'url': canonicalUrl,
      'posterUrl': item.posterUrl,
      'bannerUrl': item.bannerUrl,
      'description': item.description,
      'contentType': item.contentType.name,
      'catalogType': item.catalogType,
      'year': item.year,
      'isDubbed': item.isDubbed,
      'provider': item.provider,
      'tmdbId': item.tmdbId,
      'imdbId': item.imdbId,
      'position': positionMillis,
      'duration': durationMillis,
      'lastStreamUrl': lastStreamUrl,
      'lastEpisodeUrl': lastEpisodeUrl,
      'season': season,
      'episode': episode,
      'episodeTitle': episodeTitle,
      'episodeServerName': episodeServerName,
      'episodeServerNumber': episodeServerNumber,
      'episodePosterUrl': episodePosterUrl,
      'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
      if (syncedAccountUid != null)
        'animeWitcherSyncedUid': syncedAccountUid
      else if (previous['animeWitcherSyncedUid'] != null)
        'animeWitcherSyncedUid': previous['animeWitcherSyncedUid'],
      if (syncedAt != null)
        'animeWitcherSyncedAt': syncedAt
      else if (previous['animeWitcherSyncedAt'] != null)
        'animeWitcherSyncedAt': previous['animeWitcherSyncedAt'],
    };

    // AnimeWitcher stores one last_watched document per anime. Collapse legacy
    // URL variants before saving so opening a newer episode updates and moves
    // the same anime card instead of creating a second card.
    final staleMainKeys = <dynamic>[];
    for (var i = 0; i < _historyBox.length; i++) {
      final key = _historyBox.keyAt(i);
      if (key == canonicalKey || (key is String && key.startsWith('EP_'))) {
        continue;
      }
      final raw = _historyBox.getAt(i);
      if (raw is Map && _historyEntryMatchesUrl(raw, canonicalUrl)) {
        staleMainKeys.add(key);
      }
    }
    if (staleMainKeys.isNotEmpty) {
      await _historyBox.deleteAll(staleMainKeys);
    }

    // Save main entry (keyed by one canonical series/movie URL).
    await _historyBox.put(canonicalKey, entry);

    // Save episode-specific progress for both series and anime.
    final isSeries =
        item.contentType == MultimediaContentType.series ||
        item.contentType == MultimediaContentType.anime;

    if (isSeries && lastEpisodeUrl != null) {
      final episodeKey = "EP_${_getKey(lastEpisodeUrl)}";
      await _historyBox.put(episodeKey, entry);
    }

    _historyCacheDirty = true;
  }

  Future<void> recordHistoryOpen(
    MultimediaItem item, {
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
  }) async {
    final canonicalUrl = _canonicalMediaUrl(item.url);
    final mainRaw =
        _historyBox.get(_getKey(canonicalUrl)) ??
        _latestHistoryMainEntry(canonicalUrl);
    final main = mainRaw is Map
        ? Map<String, dynamic>.from(mainRaw)
        : <String, dynamic>{};
    Map<String, dynamic> progressSource = main;
    if (lastEpisodeUrl != null && lastEpisodeUrl.isNotEmpty) {
      final episodeRaw = _historyBox.get('EP_${_getKey(lastEpisodeUrl)}');
      if (episodeRaw is Map) {
        progressSource = Map<String, dynamic>.from(episodeRaw);
      } else if (main['lastEpisodeUrl'] != lastEpisodeUrl) {
        progressSource = <String, dynamic>{};
      }
    }

    await saveProgress(
      item,
      (progressSource['position'] as int?) ?? 0,
      (progressSource['duration'] as int?) ?? 0,
      lastStreamUrl: progressSource['lastStreamUrl'] as String?,
      lastEpisodeUrl: lastEpisodeUrl,
      season: season,
      episode: episode,
      episodeTitle: episodeTitle,
      episodeServerName: episodeServerName,
      episodeServerNumber: episodeServerNumber,
      episodePosterUrl: episodePosterUrl,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> saveContinueWatchingProgress(
    MultimediaItem item,
    int positionMillis,
    int durationMillis, {
    String? lastStreamUrl,
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
    int? progressPercent,
    int? timestamp,
    String? syncedAccountUid,
    int? syncedAt,
  }) async {
    final existing = _continueWatchingBox.get(_getKey(item.url));
    final previous = existing is Map
        ? Map<dynamic, dynamic>.from(existing)
        : const <dynamic, dynamic>{};
    final entry = <String, dynamic>{
      'title': item.title,
      'url': item.url,
      'posterUrl': item.posterUrl,
      'bannerUrl': item.bannerUrl,
      'description': item.description,
      'contentType': item.contentType.name,
      'catalogType': item.catalogType,
      'year': item.year,
      'isDubbed': item.isDubbed,
      'provider': item.provider,
      'tmdbId': item.tmdbId,
      'imdbId': item.imdbId,
      'position': positionMillis,
      'duration': durationMillis,
      'progress':
          (progressPercent ??
                  (durationMillis > 0
                      ? ((positionMillis / durationMillis) * 100).round()
                      : 0))
              .clamp(0, 100),
      'lastStreamUrl': lastStreamUrl,
      'lastEpisodeUrl': lastEpisodeUrl,
      'season': season,
      'episode': episode,
      'episodeTitle': episodeTitle,
      'episodeServerName': episodeServerName,
      'episodeServerNumber': episodeServerNumber,
      'episodePosterUrl': episodePosterUrl,
      'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
      if (syncedAccountUid != null)
        'animeWitcherSyncedUid': syncedAccountUid
      else if (previous['animeWitcherSyncedUid'] != null)
        'animeWitcherSyncedUid': previous['animeWitcherSyncedUid'],
      if (syncedAt != null)
        'animeWitcherSyncedAt': syncedAt
      else if (previous['animeWitcherSyncedAt'] != null)
        'animeWitcherSyncedAt': previous['animeWitcherSyncedAt'],
    };

    await _continueWatchingBox.put(_getKey(item.url), entry);
    final isSeries =
        item.contentType == MultimediaContentType.series ||
        item.contentType == MultimediaContentType.anime;
    if (isSeries && lastEpisodeUrl != null && lastEpisodeUrl.isNotEmpty) {
      await _continueWatchingBox.put('EP_${_getKey(lastEpisodeUrl)}', entry);
    }
    _continueWatchingCacheDirty = true;
  }

  Future<void> markContinueWatchingItemSynced(
    String url, {
    required String accountUid,
    required int syncedAt,
  }) async {
    final mainKey = _getKey(url);
    final raw = _continueWatchingBox.get(mainKey);
    if (raw is! Map) return;
    final entry = Map<String, dynamic>.from(raw);
    entry['animeWitcherSyncedUid'] = accountUid;
    entry['animeWitcherSyncedAt'] = syncedAt;
    await _continueWatchingBox.put(mainKey, entry);

    final lastEpisodeUrl = entry['lastEpisodeUrl'] as String?;
    if (lastEpisodeUrl != null && lastEpisodeUrl.isNotEmpty) {
      final episodeKey = 'EP_${_getKey(lastEpisodeUrl)}';
      final episodeRaw = _continueWatchingBox.get(episodeKey);
      if (episodeRaw is Map) {
        final episodeEntry = Map<String, dynamic>.from(episodeRaw);
        episodeEntry['animeWitcherSyncedUid'] = accountUid;
        episodeEntry['animeWitcherSyncedAt'] = syncedAt;
        await _continueWatchingBox.put(episodeKey, episodeEntry);
      }
    }
    _continueWatchingCacheDirty = true;
  }

  Future<void> removeFromContinueWatching(String url) async {
    final mainKey = _getKey(url);
    await _continueWatchingBox.delete(mainKey);
    final keysToDelete = <dynamic>[];
    for (var i = 0; i < _continueWatchingBox.length; i++) {
      final key = _continueWatchingBox.keyAt(i);
      if (key is! String || !key.startsWith('EP_')) continue;
      final raw = _continueWatchingBox.get(key);
      if (raw is Map && raw['url'] == url) keysToDelete.add(key);
    }
    await _continueWatchingBox.deleteAll(keysToDelete);
    _continueWatchingCacheDirty = true;
  }

  Future<void> clearAllContinueWatching() async {
    await _continueWatchingBox.clear();
    _continueWatchingCacheDirty = true;
  }

  List<Map<String, dynamic>> getContinueWatching() {
    if (!_continueWatchingCacheDirty && _cachedContinueWatching != null) {
      return _cachedContinueWatching!;
    }
    final items = <Map<String, dynamic>>[];
    for (var i = 0; i < _continueWatchingBox.length; i++) {
      final key = _continueWatchingBox.keyAt(i);
      if (key is String && key.startsWith('EP_')) continue;
      final raw = _continueWatchingBox.getAt(i);
      if (raw is Map) items.add(Map<String, dynamic>.from(raw));
    }
    items.sort(
      (a, b) => ((b['timestamp'] as int?) ?? 0).compareTo(
        (a['timestamp'] as int?) ?? 0,
      ),
    );
    _cachedContinueWatching = items;
    _continueWatchingCacheDirty = false;
    return items;
  }

  Future<void> markHistoryItemSynced(
    String url, {
    required String accountUid,
    required int syncedAt,
  }) async {
    final mainKey = _getKey(_canonicalMediaUrl(url));
    final raw = _historyBox.get(mainKey);
    if (raw is! Map) return;
    final entry = Map<String, dynamic>.from(raw);
    entry['animeWitcherSyncedUid'] = accountUid;
    entry['animeWitcherSyncedAt'] = syncedAt;
    await _historyBox.put(mainKey, entry);

    final lastEpisodeUrl = entry['lastEpisodeUrl'] as String?;
    if (lastEpisodeUrl != null && lastEpisodeUrl.isNotEmpty) {
      final episodeKey = 'EP_${_getKey(lastEpisodeUrl)}';
      final episodeRaw = _historyBox.get(episodeKey);
      if (episodeRaw is Map) {
        final episodeEntry = Map<String, dynamic>.from(episodeRaw);
        episodeEntry['animeWitcherSyncedUid'] = accountUid;
        episodeEntry['animeWitcherSyncedAt'] = syncedAt;
        await _historyBox.put(episodeKey, episodeEntry);
      }
    }
    _historyCacheDirty = true;
  }

  Future<void> removeFromHistory(String url) async {
    final canonicalUrl = _canonicalMediaUrl(url);
    final keysToDelete = <dynamic>{_getKey(url), _getKey(canonicalUrl)};
    for (var i = 0; i < _historyBox.length; i++) {
      final key = _historyBox.keyAt(i);
      final raw = _historyBox.getAt(i);
      if (raw is Map && _historyEntryMatchesUrl(raw, canonicalUrl)) {
        keysToDelete.add(key);
      }
    }
    await _historyBox.deleteAll(keysToDelete);

    _historyCacheDirty = true;
  }

  Future<void> updateHistoryItemTimestampAndPosition(
    String url,
    String? lastEpisodeUrl,
    int timestamp,
    int position,
  ) => _updateHistoryItem(
    _canonicalMediaUrl(url),
    lastEpisodeUrl,
    timestamp,
    position,
  );

  /// Applies a contiguous group of known Recently Watched rows in cloud
  /// order. Only legacy keys are indexed, and the lookup lives for this
  /// group, not for the lifetime of the history box.
  Future<void> syncKnownRecentHistoryRows(
    List<RecentHistoryUpdate> updates, {
    required String accountUid,
    required bool Function() isCurrent,
  }) async {
    if (updates.isEmpty || !isCurrent()) return;
    Map<String, List<dynamic>>? aliases;
    // Normal writes only add canonical/episode keys. If a raw box writer
    // adds an alias while this group is committing, rebuild before the next
    // row. Existing indexed entries are also revalidated at the point of use.
    final changes = updates.length < 2
        ? null
        : _historyBox.watch().listen((event) {
            final value = event.value;
            if (!event.deleted &&
                value is Map &&
                _legacyHistoryUrl(event.key, value) != null) {
              aliases = null;
            }
          });
    try {
      for (final update in updates) {
        if (!isCurrent()) return;
        final url = _canonicalMediaUrl(update.url);
        if (changes != null) aliases ??= _indexLegacyHistoryKeys();
        await _updateHistoryItem(
          url,
          update.episodeUrl,
          update.timestamp,
          update.position,
          aliasKeys: aliases == null ? null : aliases![url] ?? const [],
        );
        if (!isCurrent()) return;
        await markHistoryItemSynced(
          url,
          accountUid: accountUid,
          syncedAt: update.timestamp,
        );
      }
    } finally {
      await changes?.cancel();
    }
  }

  String? _legacyHistoryUrl(dynamic key, Map<dynamic, dynamic> entry) {
    if (key is String && key.startsWith('EP_')) return null;
    final rawUrl = (entry['url'] ?? '').toString();
    if (rawUrl.isEmpty) return null;
    final canonicalUrl = _canonicalMediaUrl(rawUrl);
    return key == _getKey(canonicalUrl) ? null : canonicalUrl;
  }

  Map<String, List<dynamic>> _indexLegacyHistoryKeys() {
    final aliases = <String, List<dynamic>>{};
    for (var i = 0; i < _historyBox.length; i++) {
      final key = _historyBox.keyAt(i);
      final row = _historyBox.getAt(i);
      if (row is! Map) continue;
      final url = _legacyHistoryUrl(key, row);
      if (url != null) (aliases[url] ??= []).add(key);
    }
    return aliases;
  }

  Future<void> _updateHistoryItem(
    String canonicalUrl,
    String? lastEpisodeUrl,
    int timestamp,
    int position, {
    List<dynamic>? aliasKeys,
  }) async {
    final mainKey = _getKey(canonicalUrl);
    Map<dynamic, dynamic>? latestAlias;
    var latestTimestamp = -1;
    final staleMainKeys = <dynamic>[];
    if (aliasKeys != null) {
      for (final key in aliasKeys) {
        final raw = _historyBox.get(key);
        if (raw is! Map || !_historyEntryMatchesUrl(raw, canonicalUrl)) {
          continue;
        }
        staleMainKeys.add(key);
        final timestamp = _historyTimestamp(raw);
        if (latestAlias == null || timestamp > latestTimestamp) {
          latestAlias = raw;
          latestTimestamp = timestamp;
        }
      }
    }
    final entry =
        _historyBox.get(mainKey) ??
        (aliasKeys == null
            ? _latestHistoryMainEntry(canonicalUrl)
            : latestAlias);
    if (entry is Map) {
      final updatedEntry = Map<String, dynamic>.from(entry);
      updatedEntry['url'] = canonicalUrl;
      updatedEntry['timestamp'] = timestamp;
      updatedEntry['position'] = position;

      if (aliasKeys == null) {
        for (var i = 0; i < _historyBox.length; i++) {
          final key = _historyBox.keyAt(i);
          if (key == mainKey || (key is String && key.startsWith('EP_'))) {
            continue;
          }
          final raw = _historyBox.getAt(i);
          if (raw is Map && _historyEntryMatchesUrl(raw, canonicalUrl)) {
            staleMainKeys.add(key);
          }
        }
      }
      if (staleMainKeys.isNotEmpty) {
        await _historyBox.deleteAll(staleMainKeys);
      }
      await _historyBox.put(mainKey, updatedEntry);

      if (lastEpisodeUrl != null) {
        final episodeKey = "EP_${_getKey(lastEpisodeUrl)}";
        final epEntry = _historyBox.get(episodeKey);
        if (epEntry != null) {
          final updatedEpEntry = Map<String, dynamic>.from(epEntry as Map);
          updatedEpEntry['url'] = canonicalUrl;
          updatedEpEntry['timestamp'] = timestamp;
          updatedEpEntry['position'] = position;
          await _historyBox.put(episodeKey, updatedEpEntry);
        }
      }
      _historyCacheDirty = true;
    }
  }

  Future<void> clearAllHistory() async {
    await _historyBox.clear();
    _historyCacheDirty = true;
  }

  List<Map<String, dynamic>> getWatchHistory() {
    if (!_historyCacheDirty && _cachedHistory != null) {
      return _cachedHistory!;
    }

    final newestByAnime = <String, Map<String, dynamic>>{};
    for (var i = 0; i < _historyBox.length; i++) {
      final key = _historyBox.keyAt(i);
      // Filter out episode-specific entries from the main history list
      if (key is String && key.startsWith('EP_')) continue;

      final raw = _historyBox.getAt(i);
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final rawUrl = (map['url'] ?? '').toString();
      final canonicalUrl = _canonicalMediaUrl(rawUrl);
      if (canonicalUrl.isNotEmpty) map['url'] = canonicalUrl;
      final identity = canonicalUrl.isEmpty
          ? 'legacy-history-${key.toString()}'
          : canonicalUrl;
      final previous = newestByAnime[identity];
      if (previous == null ||
          _historyTimestamp(map) > _historyTimestamp(previous)) {
        newestByAnime[identity] = map;
      }
    }
    final items = newestByAnime.values.toList(growable: false);
    // Sort by timestamp descending (newest first)
    items.sort((a, b) => _historyTimestamp(b).compareTo(_historyTimestamp(a)));

    _cachedHistory = items;
    _historyCacheDirty = false;
    return items;
  }

  Map<dynamic, dynamic>? _playbackEntry(String key) {
    final continueRaw = _continueWatchingBox.get(key);
    if (continueRaw is Map) return continueRaw;
    final historyRaw = _historyBox.get(key);
    if (historyRaw is Map) return historyRaw;
    return null;
  }

  int getPosition(String url) {
    final main = _playbackEntry(_getKey(url));
    if (main != null) return (main['position'] as int?) ?? 0;
    final episode = _playbackEntry('EP_${_getKey(url)}');
    return (episode?['position'] as int?) ?? 0;
  }

  int getEpisodePosition(
    String epUrl, {
    String? mainUrl,
    int? season,
    int? episode,
  }) {
    final ep = _playbackEntry('EP_${_getKey(epUrl)}');
    if (ep != null) return (ep['position'] as int?) ?? 0;
    if (mainUrl != null && season != null && episode != null) {
      final main = _playbackEntry(_getKey(mainUrl));
      if (main != null &&
          main['season'] == season &&
          main['episode'] == episode) {
        return (main['position'] as int?) ?? 0;
      }
    }
    return 0;
  }

  int getDuration(String url) {
    final main = _playbackEntry(_getKey(url));
    if (main != null) return (main['duration'] as int?) ?? 0;
    final episode = _playbackEntry('EP_${_getKey(url)}');
    return (episode?['duration'] as int?) ?? 0;
  }

  int getEpisodeDuration(
    String epUrl, {
    String? mainUrl,
    int? season,
    int? episode,
  }) {
    final ep = _playbackEntry('EP_${_getKey(epUrl)}');
    if (ep != null) return (ep['duration'] as int?) ?? 0;
    if (mainUrl != null && season != null && episode != null) {
      final main = _playbackEntry(_getKey(mainUrl));
      if (main != null &&
          main['season'] == season &&
          main['episode'] == episode) {
        return (main['duration'] as int?) ?? 0;
      }
    }
    return 0;
  }

  String? getLastStreamUrl(String url) {
    return _playbackEntry(_getKey(url))?['lastStreamUrl'] as String?;
  }

  String? getLastEpisodeUrl(String url) {
    return _playbackEntry(_getKey(url))?['lastEpisodeUrl'] as String?;
  }

  Future<void> clearPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      // Delete Hive Boxes (Library, History, Settings, Extensions)
      try {
        if (_libraryBox.isOpen) await _libraryBox.close();
        await Hive.deleteBoxFromDisk(kLibraryBox);
      } catch (e) {
        if (kDebugMode) debugPrint('Error deleting library box: $e');
      }
      try {
        if (_settingsBox.isOpen) await _settingsBox.close();
        await Hive.deleteBoxFromDisk(kSettingsBox);
      } catch (e) {
        if (kDebugMode) debugPrint('Error deleting settings box: $e');
      }
      try {
        if (_historyBox.isOpen) await _historyBox.close();
        await Hive.deleteBoxFromDisk(kHistoryBox);
      } catch (e) {
        if (kDebugMode) debugPrint('Error deleting history box: $e');
      }
      try {
        if (_continueWatchingBox.isOpen) await _continueWatchingBox.close();
        await Hive.deleteBoxFromDisk(kContinueWatchingBox);
      } catch (e) {
        if (kDebugMode) debugPrint('Error deleting continue watching box: $e');
      }
      try {
        if (_extensionsBox.isOpen) await _extensionsBox.close();
        await Hive.deleteBoxFromDisk(kExtensionsBox);
      } catch (e) {
        if (kDebugMode) debugPrint('Error deleting extensions box: $e');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error clearing preferences: $e');
    }
  }

  Future<void> saveDownloadMetadata(
    String taskId,
    MultimediaItem item, {
    Episode? episode,
    String? trackingUrl,
    String? filePath,
    String? logicalId,
    Map<String, dynamic>? taskSnapshot,
    bool? queueWaiting,
    bool? userPaused,
    double? lastProgress,
    int? lastExpectedBytes,
  }) async {
    await _downloadMetadata('hive.put', [
      taskId,
      {
        'item': item.toJson(),
        'episode': episode?.toJson(),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        if (trackingUrl != null && trackingUrl.isNotEmpty)
          'trackingUrl': trackingUrl,
        if (filePath != null && filePath.isNotEmpty) 'filePath': filePath,
        if (logicalId != null && logicalId.trim().isNotEmpty)
          'logicalId': logicalId.trim(),
        if (taskSnapshot != null)
          'taskSnapshot': Map<String, dynamic>.from(taskSnapshot),
        if (queueWaiting != null)
          kDownloadQueueWaitingMetadataKey: queueWaiting,
        if (userPaused != null) kDownloadUserPausedMetadataKey: userPaused,
        if (lastProgress != null)
          kDownloadLastProgressMetadataKey: lastProgress,
        if (lastExpectedBytes != null)
          kDownloadLastExpectedBytesMetadataKey: lastExpectedBytes,
      },
    ]);
  }

  Future<void> patchDownloadMetadata(
    String taskId, {
    String? trackingUrl,
    String? filePath,
    String? logicalId,
    Map<String, dynamic>? taskSnapshot,
    bool? queueWaiting,
    bool? userPaused,
    double? lastProgress,
    int? lastExpectedBytes,
  }) async {
    final map = <String, dynamic>{};
    if (trackingUrl != null && trackingUrl.isNotEmpty) {
      map['trackingUrl'] = trackingUrl;
    }
    if (filePath != null && filePath.isNotEmpty) {
      map['filePath'] = filePath;
    }
    if (logicalId != null && logicalId.trim().isNotEmpty) {
      map['logicalId'] = logicalId.trim();
    }
    if (taskSnapshot != null) {
      map['taskSnapshot'] = Map<String, dynamic>.from(taskSnapshot);
    }
    if (queueWaiting != null) {
      map[kDownloadQueueWaitingMetadataKey] = queueWaiting;
    }
    if (userPaused != null) {
      map[kDownloadUserPausedMetadataKey] = userPaused;
    }
    if (lastProgress != null) {
      map[kDownloadLastProgressMetadataKey] = lastProgress.clamp(0.0, 1.0);
    }
    if (lastExpectedBytes != null) {
      map[kDownloadLastExpectedBytesMetadataKey] = lastExpectedBytes;
    }
    await _downloadMetadata('hive.patch', [taskId, map]);
  }

  Future<Map<String, dynamic>?> getDownloadMetadata(String taskId) async {
    final data = await _downloadMetadata('hive.get', [taskId]);
    if (data == null) return null;
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async {
    final rows = await _downloadMetadata('hive.all', []) as Map;
    final result = <String, Map<String, dynamic>>{};
    for (final key in rows.keys) {
      if (key is! String) continue;
      final raw = rows[key];
      if (raw is! Map) continue;
      result[key] = Map<String, dynamic>.from(raw);
    }
    return result;
  }

  Future<void> removeDownloadMetadata(String taskId) async {
    await _downloadMetadata('hive.delete', [taskId]);
  }

  Future<bool> removeDownloadMetadataIfUnchanged(
    String taskId,
    Map<String, dynamic> expected,
  ) async {
    return await _downloadMetadata('hive.deleteIfUnchanged', [taskId, expected])
        as bool;
  }

  Future<void> deleteAllData() async {
    try {
      // Delete Extensions Folder (Application Support)
      final supportDir = await getApplicationSupportDirectory();
      final extDir = Directory('${supportDir.path}/extensions');
      if (await extDir.exists()) {
        await extDir.delete(recursive: true);
      }

      // Clear preferences and local databases.
      await clearPreferences();

      try {
        await _downloadMetadata('hive.deleteBox', []);
      } catch (_) {}

      // The OS temp root can be shared with other apps (Windows).
      await clearImageVideoCache();
    } catch (e) {
      if (kDebugMode) debugPrint('Error deleting data: $e');
    }
  }

  Future<ScopedCacheFiles> _imageVideoCacheFiles() async {
    final files = <File>[];
    final directories = <Directory>[];
    final temp = Directory(
      await (await getTemporaryDirectory()).resolveSymbolicLinks(),
    );
    for (final manager in [DefaultCacheManager(), posterCacheManager]) {
      // Await the store's existing repository initialization. Do not open another
      // repository connection or count the shared generic cache directory.
      await manager.store.getCacheSize();
      final directory = Directory(p.join(temp.path, manager.config.cacheKey));
      directories.add(directory);
      final indexed = await manager.config.repo.getAllObjects();
      for (final entry in indexed) {
        final name = entry.relativePath;
        if (name.isEmpty ||
            p.isAbsolute(name) ||
            name == '.' ||
            name == '..' ||
            p.basename(name) != name ||
            name.contains('\\')) {
          throw FileSystemException('Invalid indexed cache filename', name);
        }
        files.add(File(p.join(directory.path, name)));
      }
    }
    return ScopedCacheFiles(
      trackedFiles: files,
      trackedDirectories: directories,
      ownedDirectories: [
        Directory(p.join(temp.path, 'manga_reader_chapter_cache')),
      ],
    );
  }

  Future<int> computeImageVideoCacheBytes() async {
    if (kIsWeb) return 0;
    return (await _imageVideoCacheFiles()).bytes();
  }

  Future<void> clearImageVideoCache() async {
    if (kIsWeb) return;
    final snapshot = await _imageVideoCacheFiles();
    // Delete only indexed media and the app-owned reader cache. Unrelated temp
    // files, downloads and ambiguous orphan files are deliberately untouched.
    await snapshot.clear();
    // Leave disk-index rows to the cache manager's missing-file/expiry cleanup.
    // Deleting snapshot IDs here could erase a refreshed row and orphan its new
    // file. Missing files contribute zero bytes to our counter.
    for (final manager in [DefaultCacheManager(), posterCacheManager]) {
      manager.store.emptyMemoryCache();
    }
    PaintingBinding.instance.imageCache.clear();
    // Preserve live-image tracking: removing it cannot release mounted images
    // and may cause duplicate decodes. New requests may refill the disk cache.
    // Clearing disk cache is not a promise to reduce the process RSS to zero.
  }
}

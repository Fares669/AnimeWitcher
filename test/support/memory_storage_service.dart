import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/storage_service.dart';

/// In-memory settings box for download-queue tests. Only settings getters
/// used by Settings / DownloadService wiring are implemented.
class MemoryStorageService extends StorageService {
  MemoryStorageService({super.downloadPersistenceWorker});
  final Map<String, dynamic> settings = <String, dynamic>{};

  // Keep string settings in memory instead of accessing uninitialized Hive.
  @override
  String? getString(String key) => settings[key] as String?;

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      settings.remove(key);
    } else {
      settings[key] = value;
    }
  }

  @override
  ({List<MultimediaItem> items, int total}) getLocalLibraryShelf({
    required String category,
    required bool manga,
    required int limit,
  }) {
    final matches = getLibraryItems(category: category)
        .where(
          (item) => (item.contentType == MultimediaContentType.manga) == manga,
        )
        .toList(growable: false);
    return (
      items: matches.take(limit).toList(growable: false),
      total: matches.length,
    );
  }

  @override
  Map<String, ({List<MultimediaItem> items, int total})>
  getLocalLibraryShelves({
    required Map<String, int> limits,
    required bool manga,
  }) => {
    for (final entry in limits.entries)
      entry.key: getLocalLibraryShelf(
        category: entry.key,
        manga: manga,
        limit: entry.value,
      ),
  };

  @override
  Map<String, ({int anime, int manga})> getLocalLibraryCounts() => {
    for (final category in LibraryCategory.values)
      category.storageKey: _countLibraryItems(category.storageKey),
  };

  ({int anime, int manga}) _countLibraryItems(String category) {
    final items = getLibraryItems(category: category);
    final manga = items
        .where((item) => item.contentType == MultimediaContentType.manga)
        .length;
    return (anime: items.length - manga, manga: manga);
  }

  @override
  String? getActiveProviderId() => settings['active_provider_id'] as String?;

  @override
  Future<void> setActiveProviderId(String? id) async {
    settings['active_provider_id'] = id;
  }

  @override
  bool getDownloadDiagnosticLog() =>
      settings['download_diagnostic_log'] == true;
  @override
  Future<void> setDownloadDiagnosticLog(bool value) async {
    settings['download_diagnostic_log'] = value;
  }

  @override
  Future<void> setDownloadConcurrency(int value) async {
    settings[kDownloadConcurrencyStorageKey] = clampDownloadConcurrency(value);
  }

  @override
  int getDownloadConcurrency() {
    return parseDownloadConcurrency(settings[kDownloadConcurrencyStorageKey]);
  }

  @override
  Future<void> setDownloadParallelParts(int value) async {
    settings[kDownloadPartsSettingKey] = normalizeDownloadPartPreference(value);
  }

  @override
  int getDownloadParallelParts() {
    return normalizeDownloadPartPreference(settings[kDownloadPartsSettingKey]);
  }

  @override
  Future<void> setDownloadNotificationPrefs(
    DownloadNotificationPrefs prefs,
  ) async {
    settings[kDownloadNotificationSettingsKey] = prefs.toJson();
  }

  @override
  DownloadNotificationPrefs getDownloadNotificationPrefs() {
    return parseDownloadNotificationPrefs(
      settings[kDownloadNotificationSettingsKey],
    );
  }

  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) => defaultValue;

  @override
  String? getThemeMode() => settings['theme_mode'] as String?;

  @override
  List<String> getTaskbarOrder() => const <String>[];

  @override
  Set<String> getHiddenTaskbarItems() => const <String>{};

  @override
  String getDefaultHomeScreen() =>
      (settings['default_home_screen'] as String?) ?? '/home';

  @override
  bool isAlwaysOnTop() => false;

  @override
  bool isHighQualityPostersEnabled() => true;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => true;

  @override
  bool isArtworkFallbackEnabled() =>
      (settings['artwork_fallback_enabled'] as bool?) ?? false;

  @override
  Future<void> setArtworkFallbackEnabled(bool enabled) async {
    settings['artwork_fallback_enabled'] = enabled;
  }

  @override
  bool isMalArtworkUnreachable() =>
      (settings['mal_artwork_unreachable'] as bool?) ?? false;

  @override
  Future<void> setMalArtworkUnreachable(bool unreachable) async {
    settings['mal_artwork_unreachable'] = unreachable;
  }

  @override
  DateTime? malArtworkProbedAt() => null;

  @override
  Map<String, String> getFallbackPosters() => const <String, String>{};

  @override
  Future<void> setFallbackPosters(Map<String, String> value) async {
    settings['artwork_fallback_posters_json'] = value;
  }

  @override
  Future<int> computeImageVideoCacheBytes() async => 0;
}

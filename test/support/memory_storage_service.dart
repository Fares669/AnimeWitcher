import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/storage/storage_service.dart';

/// In-memory settings box for download-queue tests. Only settings getters
/// used by Settings / DownloadService wiring are implemented.
class MemoryStorageService extends StorageService {
  final Map<String, dynamic> settings = <String, dynamic>{};

  @override
  Future<void> setDownloadConcurrency(int value) async {
    settings[kDownloadConcurrencyStorageKey] = clampDownloadConcurrency(value);
  }

  @override
  int getDownloadConcurrency() {
    return parseDownloadConcurrency(settings[kDownloadConcurrencyStorageKey]);
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

import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'storage_service.dart';

part 'settings_repository.g.dart';

@Riverpod(keepAlive: true)
SettingsRepository settingsRepository(Ref ref) {
  return SettingsRepository(ref.watch(storageServiceProvider));
}

class SettingsRepository {
  final StorageService _storageService;

  SettingsRepository(this._storageService);

  Future<void> saveThemeMode(String mode) async {
    await _storageService.saveThemeMode(mode);
  }

  String? getThemeMode() {
    return _storageService.getThemeMode();
  }

  Future<void> setSidebarExpanded(bool expanded) async {
    await _storageService.setSidebarExpanded(expanded);
  }

  bool? getSidebarExpanded() {
    return _storageService.getSidebarExpanded();
  }

  Future<void> setDefaultHomeScreen(String path) async {
    await _storageService.setDefaultHomeScreen(path);
  }

  String getDefaultHomeScreen() {
    return _storageService.getDefaultHomeScreen();
  }

  Future<void> setTaskbarOrder(List<String> order) =>
      _storageService.setTaskbarOrder(order);

  List<String> getTaskbarOrder() => _storageService.getTaskbarOrder();

  Future<void> setHiddenTaskbarItems(Set<String> hidden) =>
      _storageService.setHiddenTaskbarItems(hidden);

  Set<String> getHiddenTaskbarItems() =>
      _storageService.getHiddenTaskbarItems();


  Future<void> setDevLoadAssets(bool enabled) async {
    await _storageService.setDevLoadAssets(enabled);
  }

  bool getDevLoadAssets() {
    return _storageService.getDevLoadAssets();
  }

  Future<void> setActiveProviderId(String? id) =>
      _storageService.setActiveProviderId(id);

  String? getActiveProviderId() {
    return _storageService.getActiveProviderId();
  }


  Future<void> setEpisodeImagesFromAniZipEnabled(bool enabled) =>
      _storageService.setEpisodeImagesFromAniZipEnabled(enabled);

  bool isEpisodeImagesFromAniZipEnabled() =>
      _storageService.isEpisodeImagesFromAniZipEnabled();

  Future<void> setHighQualityPostersEnabled(bool enabled) =>
      _storageService.setHighQualityPostersEnabled(enabled);

  bool isHighQualityPostersEnabled() =>
      _storageService.isHighQualityPostersEnabled();




  Future<void> setCustomBaseUrl(String packageName, String? url) =>
      _storageService.setCustomBaseUrl(packageName, url);

  String? getCustomBaseUrl(String packageName) =>
      _storageService.getCustomBaseUrl(packageName);

  Future<void> setLanguage(String lang) async {
    await _storageService.setLanguage(lang);
  }

  String getLanguage() {
    return _storageService.getLanguage();
  }

  Future<void> setExploreLanguage(String lang) async {
    await _storageService.setExploreLanguage(lang);
  }

  String getExploreLanguage() {
    return _storageService.getExploreLanguage();
  }


  Future<void> setAlwaysOnTop(bool enabled) async {
    await _storageService.setAlwaysOnTop(enabled);
  }

  bool isAlwaysOnTop() {
    return _storageService.isAlwaysOnTop();
  }

  Future<void> setIntroDbIntegrationEnabled(bool enabled) async {
    await _storageService.setIntroDbIntegrationEnabled(enabled);
  }

  bool isIntroDbIntegrationEnabled() {
    return _storageService.isIntroDbIntegrationEnabled();
  }

  Future<void> setAnimeSkipIntegrationEnabled(bool enabled) async {
    await _storageService.setAnimeSkipIntegrationEnabled(enabled);
  }

  bool isAnimeSkipIntegrationEnabled() {
    return _storageService.isAnimeSkipIntegrationEnabled();
  }

  Future<void> setPlayerSetting(String key, dynamic value) async {
    await _storageService.setPlayerSetting(key, value);
  }

  T? getPlayerSetting<T>(String key, {T? defaultValue}) {
    return _storageService.getPlayerSetting<T>(key, defaultValue: defaultValue);
  }

  /// Cached AnimeWitcher `Settings/constants.search_settings`.
  ///
  /// The official Android client persists these in SharedPreferences so Algolia
  /// still works when Firestore Settings is down.
  static const String _kAnimeWitcherSearchSettings =
      'animewitcher_search_settings_json';
  static const String _kAnimeWitcherSearchSettings2 =
      'animewitcher_search_settings2_json';

  Future<void> saveAnimeWitcherSearchSettings(Map<String, dynamic> value) =>
      _writeJsonMap(_kAnimeWitcherSearchSettings, value);

  Map<String, dynamic> getAnimeWitcherSearchSettings() =>
      _readJsonMap(_kAnimeWitcherSearchSettings);

  Future<void> saveAnimeWitcherSearchSettings2(Map<String, dynamic> value) =>
      _writeJsonMap(_kAnimeWitcherSearchSettings2, value);

  Map<String, dynamic> getAnimeWitcherSearchSettings2() =>
      _readJsonMap(_kAnimeWitcherSearchSettings2);

  Map<String, dynamic> _readJsonMap(String key) {
    try {
      final raw = _storageService.getString(key);
      if (raw == null || raw.trim().isEmpty) {
        return const <String, dynamic>{};
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, dynamic>{};
      return decoded.map<String, dynamic>(
        (dynamic nestedKey, dynamic nestedValue) => MapEntry<String, dynamic>(
          nestedKey.toString(),
          nestedValue,
        ),
      );
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Future<void> _writeJsonMap(String key, Map<String, dynamic> value) async {
    try {
      await _storageService.setString(key, jsonEncode(value));
    } catch (_) {}
  }

  Future<void> deleteAllData() async {
    await _storageService.deleteAllData();
  }

  Future<int> computeImageVideoCacheBytes() =>
      _storageService.computeImageVideoCacheBytes();

  Future<void> clearImageVideoCache() =>
      _storageService.clearImageVideoCache();
}

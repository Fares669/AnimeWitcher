import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/storage/anime_rift_auto_sync.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_sync.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Storage extends StorageService {
  final values = <String, String>{};
  final removedNativeUrls = <String>[];
  final removedNativeHistoryUrls = <String>[];
  int clearedNativeContinue = 0;
  @override
  Future<void> removeFromHistory(String url) async =>
      removedNativeHistoryUrls.add(url);
  @override
  Future<void> clearAllContinueWatching() async {
    clearedNativeContinue++;
  }

  @override
  Future<void> removeFromContinueWatching(String url) async =>
      removedNativeUrls.add(url);
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  List<Map<String, dynamic>> getWatchHistory() => [
    {'title': 'Native', 'url': 'same'},
  ];
  @override
  List<Map<String, dynamic>> getContinueWatching() => [];
}

class _Provider extends AnimeWitcherProvider {
  _Provider(this.id);
  final String id;
  @override
  String get packageName => id;
  @override
  String get name => id;
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => ['ar'];
  @override
  Set<ProviderType> get supportedTypes => {ProviderType.anime};
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => [];
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => {};
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) async => [];
}

class _Active extends ActiveProvider {
  _Active(this.initial);
  final AnimeWitcherProvider initial;
  @override
  AnimeWitcherProvider? build() => initial;
  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

class _CountingRift extends AnimeRiftProvider {
  int fullImports = 0;
  int historyImports = 0;

  @override
  Future<bool> restoreAccountSession() async => true;

  @override
  Future<AnimeRiftCloudImportResult> importCloudLibrary(
    StorageService storage,
  ) async {
    fullImports++;
    return const AnimeRiftCloudImportResult(
      favorites: 0,
      categories: 0,
      history: 0,
      skipped: 0,
    );
  }

  @override
  Future<AnimeRiftCloudImportResult> importCloudHistory(
    StorageService storage,
  ) async {
    historyImports++;
    return const AnimeRiftCloudImportResult(
      favorites: 0,
      categories: 0,
      history: 0,
      skipped: 0,
    );
  }
}

void main() {
  test(
    'Rift continue-watching refresh fetches history, not six cloud shelves',
    () async {
      AnimeRiftLocalAccountScope.activate('history-only');
      addTearDown(AnimeRiftLocalAccountScope.reset);
      final storage = _Storage();
      final rift = _CountingRift();
      final coordinator = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => rift,
      );
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          activeProviderProvider.overrideWith(() => _Active(rift)),
          riftAutoSyncProvider.overrideWithValue(coordinator),
        ],
      );
      addTearDown(() {
        container.dispose();
        coordinator.dispose();
      });
      await container
          .read(continueWatchingProvider.notifier)
          .refreshFromServer();
      expect(rift.historyImports, 1);
      expect(rift.fullImports, 0);
    },
  );

  test(
    'history and continue watching follow source without cross-account sync',
    () async {
      final storage = _Storage();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      final native = _Provider('com.fares669.animewitcher.native');
      final rift = _Provider(animeRiftProviderId);
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          activeProviderProvider.overrideWith(() => _Active(rift)),
        ],
      );
      addTearDown(container.dispose);
      final item = MultimediaItem(
        title: 'Rift',
        url: 'same',
        posterUrl: '',
        provider: animeRiftProviderId,
      );
      await container
          .read(watchHistoryProvider.notifier)
          .recordOpened(item, lastEpisodeUrl: 'ep');
      await container
          .read(continueWatchingProvider.notifier)
          .saveProgress(item, 25, 100, lastEpisodeUrl: 'ep');
      expect(container.read(watchHistoryProvider).single.item.title, 'Rift');
      expect(container.read(continueWatchingProvider).single.position, 25);
      final nativeItem = MultimediaItem(
        title: 'Native',
        url: 'same',
        posterUrl: '',
        provider: native.packageName,
      );
      await container
          .read(continueWatchingProvider.notifier)
          .removeForItem(nativeItem);
      expect(storage.removedNativeUrls, ['same']);
      expect(
        container.read(continueWatchingProvider).single.item.title,
        'Rift',
      );
      await container
          .read(watchHistoryProvider.notifier)
          .removeForItem(nativeItem);
      expect(storage.removedNativeHistoryUrls, ['same']);
      expect(container.read(watchHistoryProvider).single.item.title, 'Rift');
      await container
          .read(continueWatchingProvider.notifier)
          .clearAllFor(native.packageName);
      expect(storage.clearedNativeContinue, 1);
      expect(
        container.read(continueWatchingProvider).single.item.title,
        'Rift',
      );
      await container.read(activeProviderProvider.notifier).set(native);
      expect(container.read(watchHistoryProvider).single.item.title, 'Native');
      expect(container.read(continueWatchingProvider), isEmpty);
      await container
          .read(watchHistoryProvider.notifier)
          .recordOpened(item, lastEpisodeUrl: 'ep');
      expect(container.read(watchHistoryProvider).single.item.title, 'Native');
      await container.read(activeProviderProvider.notifier).set(rift);
      expect(container.read(watchHistoryProvider).single.item.title, 'Rift');
    },
  );
}

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestSettings extends SettingsRepository {
  _TestSettings(this.savedId) : super(StorageService());

  String? savedId;

  @override
  String? getActiveProviderId() => savedId;

  @override
  Future<void> setActiveProviderId(String? id) async => savedId = id;
}

ProviderContainer _container(_TestSettings settings) {
  final storage = StorageService();
  return ProviderContainer(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(settings),
      dioClientProvider.overrideWithValue(Dio()),
      animeWitcherAccountServiceProvider.overrideWithValue(
        AnimeWitcherAccountService(
          storage: storage,
          secureStorage: SecureTokenStorage(storage),
        ),
      ),
    ],
  );
}

void main() {
  test(
    'rebuilding provider registry preserves Rift in-memory session owner',
    () {
      final container = _container(_TestSettings(null));
      addTearDown(container.dispose);
      final first = container.read(extensionManagerProvider).last;
      container.invalidate(extensionManagerProvider);
      final after = container.read(extensionManagerProvider).last;
      expect(after, same(first));
    },
  );

  test('registers Anime Rift after the default native anime provider', () {
    final settings = _TestSettings(null);
    final container = _container(settings);
    addTearDown(container.dispose);

    final registered = container.read(extensionManagerProvider);
    expect(registered, hasLength(2));
    expect(registered.first, isA<AnimeWitcherNativeProvider>());
    expect(registered.last, isA<AnimeRiftProvider>());
    expect(registered.last.packageName, animeRiftProviderId);
    expect(registered.last.supportedTypes, {ProviderType.anime});
    expect(
      container
          .read(extensionManagerProvider.notifier)
          .getProvider(animeRiftProviderId),
      same(registered.last),
    );
    expect(container.read(activeProviderProvider), same(registered.first));
  });

  test(
    'restores Anime Rift selection and persists a switch to native',
    () async {
      final settings = _TestSettings(animeRiftProviderId);
      final container = _container(settings);
      addTearDown(container.dispose);

      final registered = container.read(extensionManagerProvider);
      expect(container.read(activeProviderProvider), same(registered.last));
      await expectLater(
        registered.last.search('offline'),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );

      await container
          .read(activeProviderProvider.notifier)
          .set(registered.first);
      expect(settings.savedId, registered.first.packageName);

      final restored = _container(settings);
      addTearDown(restored.dispose);
      expect(
        restored.read(activeProviderProvider)?.packageName,
        registered.first.packageName,
      );
    },
  );

  test(
    'unknown persisted provider falls back without rewriting preference',
    () async {
      final settings = _TestSettings('missing.provider');
      final container = _container(settings);
      addTearDown(container.dispose);

      final registered = container.read(extensionManagerProvider);
      expect(container.read(activeProviderProvider), same(registered.first));

      await Future<void>.delayed(Duration.zero);
      expect(settings.savedId, 'missing.provider');
    },
  );
}

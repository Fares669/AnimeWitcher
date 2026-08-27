import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../account/account_providers.dart';
import '../network/dio_client_provider.dart';
import '../storage/settings_repository.dart';
import 'base_provider.dart';
import 'providers/animewitcher_native_provider.dart';

part 'extension_manager.g.dart';

/// Built-in provider registry for the standalone AnimeWitcher app.
@Riverpod(keepAlive: true)
class ExtensionManager extends _$ExtensionManager {
  @override
  List<AnimeWitcherProvider> build() {
    return <AnimeWitcherProvider>[
      AnimeWitcherNativeProvider(
        ref.watch(dioClientProvider),
        ref.watch(settingsRepositoryProvider),
        resolveAnimeByMalIds: ref
            .watch(animeWitcherAccountServiceProvider)
            .resolveAnimeByMalIds,
        isEcchiHidden: () =>
            ref
                .read(animeWitcherAccountServiceProvider)
                .snapshot
                .profile
                ?.privacySettings
                .hideEcchiAnime ??
            false,
      ),
    ];
  }

  List<AnimeWitcherProvider> getAllProviders() =>
      List<AnimeWitcherProvider>.unmodifiable(state);

  AnimeWitcherProvider? getProvider(String id) {
    final value = id.trim();
    if (value.isEmpty) return null;
    for (final provider in state) {
      if (provider.packageName == value || provider.name == value) {
        return provider;
      }
    }
    return null;
  }
}

@Riverpod(keepAlive: true)
class ProviderResolutionLoading extends _$ProviderResolutionLoading {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

/// AnimeWitcher Native is the built-in provider and is selected automatically.
@Riverpod(keepAlive: true)
class ActiveProvider extends _$ActiveProvider {
  @override
  AnimeWitcherProvider? build() {
    final providers = ref.watch(extensionManagerProvider);
    if (providers.isEmpty) return null;

    final storage = ref.read(settingsRepositoryProvider);
    final storedId = storage.getActiveProviderId();
    final selected = storedId == null
        ? providers.first
        : (ref.read(extensionManagerProvider.notifier).getProvider(storedId) ??
            providers.first);

    if (storedId != selected.packageName) {
      Future.microtask(() => storage.setActiveProviderId(selected.packageName));
    }
    return selected;
  }

  Future<void> set(AnimeWitcherProvider? provider) async {
    final providers = ref.read(extensionManagerProvider);
    final next = provider ?? (providers.isEmpty ? null : providers.first);
    state = next;
    ref.read(providerResolutionLoadingProvider.notifier).set(false);
    await ref
        .read(settingsRepositoryProvider)
        .setActiveProviderId(next?.packageName);
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../account/account_providers.dart';
import '../account/anime3rb_account_service.dart';
import '../account/witanime_account_service.dart';
import '../network/dio_client_provider.dart';
import '../storage/settings_repository.dart';
import 'base_provider.dart';
import 'providers/anime3rb_provider.dart';
import 'providers/animewitcher_native_provider.dart';
import 'providers/witanime_provider.dart';

part 'extension_manager.g.dart';

final witanimeCatalogProvider = Provider<WitanimeProvider?>((ref) {
  if (!const bool.fromEnvironment(
    'WITANIME_CATALOG_ENABLED',
    defaultValue: true,
  )) {
    return null;
  }

  return WitanimeProvider.withTransport(ref.watch(witanimeTransportProvider));
});

final anime3rbCatalogProvider = Provider<Anime3rbProvider?>((ref) {
  if (!const bool.fromEnvironment(
    'ANIME3RB_CATALOG_ENABLED',
    defaultValue: true,
  )) {
    return null;
  }

  return Anime3rbProvider.withTransport(ref.watch(anime3rbTransportProvider));
});

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
      ?ref.watch(witanimeCatalogProvider),
      ?ref.watch(anime3rbCatalogProvider),
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

/// Active anime catalog provider, persisted across app launches.
@Riverpod(keepAlive: true)
class ActiveProvider extends _$ActiveProvider {
  Future<void> _pendingSave = Future<void>.value();

  Future<void> _saveSelection(String? id) {
    final storage = ref.read(settingsRepositoryProvider);
    final next = _pendingSave
        .catchError((Object _) {})
        .then((_) => storage.setActiveProviderId(id));
    _pendingSave = next;
    return next;
  }

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

    // A missing preference can safely initialize to the built-in default.
    // An unknown persisted ID may belong to a temporarily unavailable or
    // future provider, so fall back for this session without destroying it.
    if (storedId == null) {
      Future.microtask(() {
        if (ref.mounted && state?.packageName == selected.packageName) {
          _saveSelection(selected.packageName);
        }
      });
    }
    return selected;
  }

  Future<void> set(AnimeWitcherProvider? provider) async {
    final providers = ref.read(extensionManagerProvider);
    final next = provider ?? (providers.isEmpty ? null : providers.first);
    state = next;
    ref.read(providerResolutionLoadingProvider.notifier).set(false);
    await _saveSelection(next?.packageName);
  }
}

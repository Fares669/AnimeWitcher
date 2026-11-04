import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../account/account_providers.dart';
import '../network/dio_client_provider.dart';
import '../storage/anime_rift_account_scope.dart';
import '../storage/settings_repository.dart';
import 'base_provider.dart';
import 'providers/anime_rift_provider.dart';
import 'providers/animewitcher_native_provider.dart';

part 'extension_manager.g.dart';

/// Built-in provider registry for the standalone AnimeWitcher app.
@Riverpod(keepAlive: true)
class ExtensionManager extends _$ExtensionManager {
  @override
  List<AnimeWitcherProvider> build() {
    final rift = AnimeRiftProvider();
    // Restore the independent Rift identity before the user opens settings.
    // Refresh visible local library/history when secure storage selects a
    // different account partition. Failure remains visible in account settings.
    unawaited(
      Future<void>.microtask(() async {
        final previous = AnimeRiftLocalAccountScope.accountHash;
        try {
          await rift.restoreAccountSession();
        } catch (_) {
          return;
        }
        if (ref.mounted && previous != AnimeRiftLocalAccountScope.accountHash) {
          ref.read(accountDataRevisionProvider.notifier).bump();
        }
      }),
    );
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
      rift,
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

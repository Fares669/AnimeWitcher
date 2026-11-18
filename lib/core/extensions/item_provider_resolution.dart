import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'base_provider.dart';
import 'extension_manager.dart';

final itemSourceProvider = Provider.autoDispose
    .family<AnimeWitcherProvider?, String?>((ref, providerId) {
      final active = ref.watch(activeProviderProvider);
      final resolved = resolveItemProvider(
        [if (active != null) active],
        providerId,
        active,
      );
      return resolved ??
          resolveItemProvider(
            ref.watch(extensionManagerProvider),
            providerId,
            null,
          );
    });

/// An explicit source identity must never silently resolve to another source.
AnimeWitcherProvider? resolveItemProvider(
  Iterable<AnimeWitcherProvider> providers,
  String? providerId,
  AnimeWitcherProvider? legacyFallback,
) {
  final id = providerId?.trim() ?? '';
  if (id.isEmpty || id == 'Local' || id == 'Remote') return legacyFallback;
  for (final provider in providers) {
    if (provider.packageName == id || provider.name == id) return provider;
  }
  return null;
}

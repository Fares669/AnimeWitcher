import '../account/animewitcher_comment_models.dart'
    show animeWitcherNativeProviderId;
import '../storage/provider_local_library.dart' show animeRiftProviderId;
import 'base_provider.dart';

/// An explicit source identity must never silently resolve to another source.
/// Legacy untagged Witcher items must not be routed to Rift after a switch.
AnimeWitcherProvider? resolveItemProvider(
  Iterable<AnimeWitcherProvider> providers,
  String? providerId,
  AnimeWitcherProvider? legacyFallback,
) {
  final id = providerId?.trim() ?? '';
  if (id.isEmpty || id == 'Local' || id == 'Remote') {
    if (legacyFallback?.packageName != animeRiftProviderId) {
      return legacyFallback;
    }
    for (final provider in providers) {
      if (provider.packageName == animeWitcherNativeProviderId) return provider;
    }
    return null;
  }
  for (final provider in providers) {
    if (provider.packageName == id || provider.name == id) return provider;
  }
  return null;
}

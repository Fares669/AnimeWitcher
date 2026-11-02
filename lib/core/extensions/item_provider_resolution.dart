import 'base_provider.dart';

/// An explicit source identity must never silently resolve to another source.
/// Untagged legacy items retain their existing active-provider fallback.
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

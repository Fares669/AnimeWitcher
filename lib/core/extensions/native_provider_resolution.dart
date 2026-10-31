import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'base_provider.dart';
import 'extension_manager.dart';
import 'providers/animewitcher_native_provider.dart';

AnimeWitcherNativeProvider? _scanInstalled(
  Iterable<AnimeWitcherProvider> installed,
) {
  for (final provider in installed) {
    if (provider is AnimeWitcherNativeProvider) return provider;
  }
  return null;
}

/// The app's own catalogue provider: the active one when it is the
/// native provider, otherwise the first native provider installed,
/// otherwise null. Screens that browse the built-in catalogue all
/// resolve it this one way. The installed list is only read when the
/// active provider is not already the native one.
extension NativeProviderRefLookup on Ref {
  AnimeWitcherNativeProvider? get nativeProvider {
    final active = read(activeProviderProvider);
    if (active is AnimeWitcherNativeProvider) return active;
    return _scanInstalled(read(extensionManagerProvider));
  }
}

/// The same lookup for widget refs, which are a separate type.
extension NativeProviderWidgetRefLookup on WidgetRef {
  AnimeWitcherNativeProvider? get nativeProvider {
    final active = read(activeProviderProvider);
    if (active is AnimeWitcherNativeProvider) return active;
    return _scanInstalled(read(extensionManagerProvider));
  }
}

/// The failure screens record when the lookup finds no native provider.
StateError nativeProviderUnavailable() =>
    StateError('AnimeWitcher Native unavailable');

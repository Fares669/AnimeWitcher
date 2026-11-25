import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/storage/storage_service.dart';

final latestEpisodesSettingsProvider =
    NotifierProvider<LatestEpisodesSettings, Set<String>>(
      LatestEpisodesSettings.new,
    );

/// Remembers which sources to show when they are secondary.
class LatestEpisodesSettings extends Notifier<Set<String>> {
  static const _storageKey = 'home_secondary_latest_episodes';

  @override
  Set<String> build() {
    final saved = ref.watch(storageServiceProvider).getString(_storageKey);
    return Set.unmodifiable(
      saved?.split(',').where((id) => id.isNotEmpty) ?? const <String>[],
    );
  }

  Future<void> setEnabled(String id, bool enabled) async {
    if (id == ref.read(activeProviderProvider)?.packageName ||
        state.contains(id) == enabled) {
      return;
    }
    final next = {...state};
    if (enabled) {
      next.add(id);
    } else {
      next.remove(id);
    }
    state = Set.unmodifiable(next);
    await ref
        .read(storageServiceProvider)
        .setString(_storageKey, next.isEmpty ? null : next.join(','));
  }
}

final secondaryLatestEpisodesProvider = FutureProvider.autoDispose
    .family<MapEntry<String, List<MultimediaItem>>?, AnimeWitcherProvider>(
      (ref, source) => source.getLatestHomeEpisodes(),
      retry: (_, _) => null,
    );

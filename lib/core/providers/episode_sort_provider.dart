import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/storage_service.dart';

const episodeSortAscendingSettingKey = 'episode_sort_ascending';

final episodeSortAscendingProvider =
    NotifierProvider<EpisodeSortAscendingNotifier, bool>(
      EpisodeSortAscendingNotifier.new,
    );

class EpisodeSortAscendingNotifier extends Notifier<bool> {
  @override
  bool build() {
    return ref
            .read(storageServiceProvider)
            .getPlayerSetting<bool>(
              episodeSortAscendingSettingKey,
              defaultValue: true,
            ) ??
        true;
  }

  void setAscending(bool value) {
    if (state == value) return;
    state = value;
    unawaited(
      ref
          .read(storageServiceProvider)
          .setPlayerSetting(episodeSortAscendingSettingKey, value),
    );
  }
}

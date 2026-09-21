import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_repository.dart';
import 'manga_reader_settings.dart';

final mangaReaderSettingsProvider =
    NotifierProvider<MangaReaderSettingsNotifier, MangaReaderSettings>(
      MangaReaderSettingsNotifier.new,
    );

class MangaReaderSettingsNotifier extends Notifier<MangaReaderSettings> {
  @override
  MangaReaderSettings build() {
    final raw = ref.watch(settingsRepositoryProvider).getMangaReaderSettings();
    return raw.isEmpty
        ? const MangaReaderSettings()
        : MangaReaderSettings.fromJson(raw);
  }

  Future<void> setSettings(MangaReaderSettings value) async {
    state = value;
    await ref
        .read(settingsRepositoryProvider)
        .saveMangaReaderSettings(value.toJson());
  }

  Future<void> update(
    MangaReaderSettings Function(MangaReaderSettings current) transform,
  ) =>
      setSettings(transform(state));

  Future<void> reset() => setSettings(const MangaReaderSettings());
}

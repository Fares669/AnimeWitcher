import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/settings_repository.dart';

final mangaReaderCustomCoversProvider =
    NotifierProvider<MangaReaderCustomCoversNotifier, Map<String, String>>(
      MangaReaderCustomCoversNotifier.new,
    );

class MangaReaderCustomCoversNotifier extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() =>
      ref.watch(settingsRepositoryProvider).getMangaReaderCustomCovers();

  Future<void> setCover(String mangaUrl, String fileUri) async {
    final key = mangaUrl.trim();
    final value = fileUri.trim();
    if (key.isEmpty || value.isEmpty) return;
    final next = <String, String>{...state, key: value};
    state = next;
    await ref
        .read(settingsRepositoryProvider)
        .saveMangaReaderCustomCovers(next);
  }

  Future<void> clearCover(String mangaUrl) async {
    final key = mangaUrl.trim();
    if (!state.containsKey(key)) return;
    final next = <String, String>{...state}..remove(key);
    state = next;
    await ref
        .read(settingsRepositoryProvider)
        .saveMangaReaderCustomCovers(next);
  }
}

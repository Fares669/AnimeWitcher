import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/provider_local_history.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Memory extends StorageService {
  final values = <String, String>{'legacy_native_history': 'untouched'};
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String? value) async {
    await Future<void>.delayed(Duration.zero);
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

void main() {
  test('progress, continue watching and history survive restart without mixing providers', () async {
    final storage = _Memory();
    final rift = ProviderLocalHistory(storage, 'rift');
    final other = ProviderLocalHistory(storage, 'other');
    final item = MultimediaItem(
      title: 'Anime',
      url: 'same',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
    );
    await Future.wait([
      rift.recordOpened(item, episodeUrl: 'episode'),
      other.saveProgress(item, 9, 100, episodeUrl: 'episode'),
    ]);
    await rift.saveProgress(item, 30, 100, episodeUrl: 'episode');
    final restored = ProviderLocalHistory(storage, 'rift');
    expect(restored.history().single.item.provider, 'rift');
    expect(restored.continueWatching().single.position, 30);
    expect(restored.position('same', 'episode'), 30);
    expect(other.position('same', 'episode'), 9);
    await restored.clearContinueWatching();
    expect(restored.continueWatching(), isEmpty);
    expect(restored.history(), hasLength(1));
    expect(other.continueWatching(), hasLength(1));
    expect(storage.values['legacy_native_history'], 'untouched');
  });
  test(
    'watched episode states are isolated by source and survive restart',
    () async {
      final storage = _Memory();
      final rift = ProviderLocalHistory(storage, 'rift');
      final other = ProviderLocalHistory(storage, 'other');
      final episode = Episode(name: 'Episode', url: 'same');
      await rift.setWatched('anime', episode, true);
      expect(
        ProviderLocalHistory(storage, 'rift').isWatched('anime', episode),
        isTrue,
      );
      expect(other.isWatched('anime', episode), isNull);
      await rift.setWatched('anime', episode, false);
      expect(rift.isWatched('anime', episode), isFalse);
    },
  );

  test('invalid stored history is not overwritten', () async {
    final storage = _Memory();
    final history = ProviderLocalHistory(storage, 'rift');
    storage.values[history.storageKey] = '{broken';
    await expectLater(
      history.recordOpened(
        MultimediaItem(title: 'x', url: 'id', posterUrl: ''),
      ),
      throwsFormatException,
    );
    expect(storage.values[history.storageKey], '{broken');
  });
}

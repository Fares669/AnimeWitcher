import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_cover_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeCoverSettingsRepository extends SettingsRepository {
  _FakeCoverSettingsRepository() : super(StorageService());

  Map<String, String> covers = <String, String>{
    'https://animewitcher.com/manga/old': 'file:///old.webp',
  };

  @override
  Map<String, String> getMangaReaderCustomCovers() =>
      Map<String, String>.from(covers);

  @override
  Future<void> saveMangaReaderCustomCovers(Map<String, String> value) async {
    covers = Map<String, String>.from(value);
  }
}

void main() {
  test('reader custom cover persists per Manga without touching cloud item', () async {
    final repository = _FakeCoverSettingsRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(mangaReaderCustomCoversProvider)[
        'https://animewitcher.com/manga/old'
      ],
      'file:///old.webp',
    );

    await container
        .read(mangaReaderCustomCoversProvider.notifier)
        .setCover(
          'https://animewitcher.com/manga/m1',
          'file:///covers/m1.webp',
        );

    expect(
      repository.covers['https://animewitcher.com/manga/m1'],
      'file:///covers/m1.webp',
    );
    expect(
      container.read(mangaReaderCustomCoversProvider)[
        'https://animewitcher.com/manga/m1'
      ],
      'file:///covers/m1.webp',
    );
  });
}

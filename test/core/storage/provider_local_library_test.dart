import 'dart:convert';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Memory extends StorageService {
  final values = <String, String>{'legacy_native': 'untouched'};
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
  test(
    'cached shelf refreshes when another library instance edits storage',
    () async {
      final storage = _Memory();
      final first = ProviderLocalLibrary(storage, 'cache-provider');
      final second = ProviderLocalLibrary(storage, 'cache-provider');
      final item = MultimediaItem(
        title: 'Cached',
        url: 'cache-id',
        posterUrl: '',
      );
      expect(first.items(LibraryCategory.completed), isEmpty);
      await second.setCategory(item, LibraryCategory.completed);
      expect(first.items(LibraryCategory.completed), hasLength(1));
      await second.clearCategory(item.url);
      expect(first.items(LibraryCategory.completed), isEmpty);
      expect(first.isFavorite(item.url), false);
    },
  );
  test(
    'favorites and categories persist independently for the same id',
    () async {
      final storage = _Memory();
      final rift = ProviderLocalLibrary(storage, 'animerift');
      final other = ProviderLocalLibrary(storage, 'other');
      final item = MultimediaItem(title: 'Show', url: 'same', posterUrl: '');
      await Future.wait([
        rift.setFavorite(item, true),
        rift.setCategory(item, LibraryCategory.planToWatch),
        other.setCategory(item, LibraryCategory.completed),
      ]);
      final restarted = ProviderLocalLibrary(storage, 'animerift');
      expect(restarted.isFavorite('same'), isTrue);
      expect(restarted.category('same'), LibraryCategory.planToWatch);
      expect(other.isFavorite('same'), isFalse);
      expect(other.category('same'), LibraryCategory.completed);
      expect(
        restarted.items(LibraryCategory.favorite).single.provider,
        'animerift',
      );
      expect(storage.values['legacy_native'], 'untouched');
    },
  );

  test('corrupt data is never overwritten', () async {
    final storage = _Memory();
    final library = ProviderLocalLibrary(storage, 'animerift');
    storage.values[library.storageKey] = '{broken';
    final item = MultimediaItem(title: 'Show', url: 'same', posterUrl: '');
    await expectLater(library.setFavorite(item, true), throwsFormatException);
    expect(storage.values[library.storageKey], '{broken');
  });

  test(
    'Rift www and canonical catalog URLs share one library identity',
    () async {
      final storage = _Memory();
      final library = ProviderLocalLibrary(storage, animeRiftProviderId);
      final item = MultimediaItem(
        title: 'Rift',
        url: 'https://www.anime-rift.com/anime/42',
        posterUrl: '',
        provider: animeRiftProviderId,
      );

      await library.setFavorite(item, true);

      const canonical = 'https://anime-rift.com/anime/42';
      expect(library.isFavorite(canonical), isTrue);
      expect(library.item(canonical)?.url, canonical);
      expect(library.allItems(), hasLength(1));
    },
  );

  test(
    'Rift library persists catalog metadata without playback secrets',
    () async {
      final storage = _Memory();
      final library = ProviderLocalLibrary(storage, animeRiftProviderId);
      final item = MultimediaItem(
        title: 'Rift',
        url: 'https://anime-rift.com/anime/42',
        posterUrl: 'https://anime-rift.com/poster.jpg',
        provider: animeRiftProviderId,
        headers: const {'Authorization': 'Bearer secret-header'},
        syncData: const {'secret': 'secret-sync'},
        streams: const [
          StreamResult(
            url: 'https://cdn.example/video.mp4?token=secret-stream',
            source: 'Rift',
          ),
        ],
        episodes: [
          Episode(
            name: '1',
            url: 'https://anime-rift.com/episode/1?token=secret-episode',
          ),
        ],
      );

      await library.setFavorite(item, true);

      final persisted = storage.values[library.storageKey]!;
      expect(persisted, contains('"title":"Rift"'));
      expect(persisted, isNot(contains('secret-header')));
      expect(persisted, isNot(contains('secret-sync')));
      expect(persisted, isNot(contains('secret-stream')));
      expect(persisted, isNot(contains('secret-episode')));
    },
  );

  test(
    'legacy Rift library rows are sanitized when they are migrated',
    () async {
      final storage = _Memory();
      final library = ProviderLocalLibrary(storage, animeRiftProviderId);
      storage.values[library.storageKey] = jsonEncode({
        'https://www.anime-rift.com/anime/42?token=legacy': {
          'item': {
            'title': 'Legacy Rift',
            'url': 'https://www.anime-rift.com/anime/42?token=legacy',
            'posterUrl': '',
            'provider': animeRiftProviderId,
            'headers': {'Authorization': 'Bearer legacy-secret'},
            'syncData': {'token': 'legacy-sync-secret'},
            'streams': [
              {
                'url':
                    'https://cdn.invalid/video.mp4?token=legacy-stream-secret',
                'source': 'Rift',
                'drmKey': 'legacy-drm-secret',
              },
            ],
          },
          'favorite': true,
          'category': LibraryCategory.planToWatch.storageKey,
        },
      });

      await library.setFavorite(
        MultimediaItem(
          title: 'Legacy Rift',
          url: 'https://anime-rift.com/anime/42',
          posterUrl: '',
          provider: animeRiftProviderId,
        ),
        true,
      );

      final persisted = storage.values[library.storageKey]!;
      expect(persisted, contains('https://anime-rift.com/anime/42'));
      expect(persisted, isNot(contains('legacy-secret')));
      expect(persisted, isNot(contains('legacy-sync-secret')));
      expect(persisted, isNot(contains('legacy-stream-secret')));
      expect(persisted, isNot(contains('legacy-drm-secret')));
      expect(
        library.category('https://anime-rift.com/anime/42'),
        LibraryCategory.planToWatch,
      );
    },
  );
}

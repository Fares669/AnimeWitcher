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
}

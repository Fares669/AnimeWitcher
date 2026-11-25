import 'dart:io';

import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

Map<String, dynamic> _row(
  String url, {
  int updatedAt = 10,
  dynamic syncedAt = 11,
  dynamic owner = 'owner',
  String? category,
  dynamic favorite,
}) => {
  'url': url,
  'updatedAt': updatedAt,
  'animeWitcherSyncedAt': syncedAt,
  'animeWitcherSyncedUid': owner,
  if (favorite != null) 'isFavorite': favorite,
  if (category != null) 'libraryCategory': category,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageService storage;
  late Box<dynamic> box;

  setUp(() async {
    final root = await Directory.systemTemp.createTemp('aw-library-point-');
    final previous = PathProviderPlatform.instance;
    final worker = DownloadPersistenceWorker.forDirectory(root.path);
    PathProviderPlatform.instance = _Paths(root.path);
    addTearDown(() async {
      await Hive.close();
      await worker.close();
      PathProviderPlatform.instance = previous;
      await root.delete(recursive: true);
    });
    storage = StorageService(downloadPersistenceWorker: worker);
    await storage.init();
    box = Hive.box<dynamic>(StorageService.kLibraryBox);
  });

  test(
    'point reads keep the first ordered legacy row and sync ownership',
    () async {
      const canonical = 'https://animewitcher.com/watch/series';
      const alias = ' HTTP://WWW.ANIMEWITCHER.COM/watch/series/extra?fake=x ';
      await box.putAll({
        canonical: _row(canonical, updatedAt: 90, owner: 'Canonical Owner'),
        'b-legacy': _row(canonical, updatedAt: 20, favorite: false),
        'a-legacy': _row(
          alias,
          updatedAt: 15,
          syncedAt: '14',
          owner: ' First Owner ',
          category: 'on_Hold',
          favorite: '1',
        ),
        8: 'unrelated non-map',
      });
      for (final url in [canonical, alias, canonical, alias]) {
        expect(storage.getLibraryItemUpdatedAt(url), 15);
        expect(storage.getLibraryItemSyncedAt(url), 14);
        expect(storage.getLibraryItemSyncedAccountUid(url), 'First Owner');
        expect(storage.getLibraryItemCategory(url), 'onHold');
        expect(storage.isLibraryItemFavorite(url), isTrue);
        expect(storage.isInLibrary(url), isTrue);
      }

      // An account update changes live fields without changing the normalized URL.
      await storage.markLibraryItemSynced(
        canonical,
        accountUid: 'Edited Owner',
        syncedAt: 23,
      );
      expect(storage.getLibraryItemSyncedAt(alias), 23);
      expect(storage.getLibraryItemSyncedAccountUid(alias), 'Edited Owner');
      expect(storage.getLibraryItemUpdatedAt(alias), 15);
      await storage.setLibraryItemCategory(alias, 'completed');
      expect(storage.getLibraryItemCategory(canonical), 'completed');
      expect(storage.isLibraryItemFavorite(canonical), isTrue);
      expect(storage.getLibraryItemSyncedAccountUid(canonical), 'Edited Owner');

      final write = box.put(
        0,
        _row(alias, updatedAt: 41, owner: 'New Earlier', favorite: 'false'),
      );
      expect(storage.getLibraryItemUpdatedAt(canonical), 41);
      expect(storage.isLibraryItemFavorite(canonical), isFalse);
      await write;
      final delete = box.delete(0);
      expect(storage.getLibraryItemSyncedAccountUid(canonical), 'Edited Owner');
      await delete;

      await box.delete('a-legacy');
      expect(storage.getLibraryItemUpdatedAt(alias), 20);
      expect(storage.isLibraryItemFavorite(alias), isFalse);
      await storage.removeFromLibrary(canonical);
      expect(storage.isInLibrary(canonical), isFalse);
      expect(storage.getLibraryItemSyncedAccountUid(alias), isNull);
      expect(storage.getLibraryItemUpdatedAt(alias), 0);
    },
  );

  test(
    'row object changes, malformed URLs, and direct canonical keys stay live',
    () async {
      const original = 'https://extension.example.test/one';
      const changed = 'https://extension.example.test/two';
      const malformed = 'http://[not-a-host';
      final mutable = _row(original, owner: 'Owner A');
      await box.putAll({
        'a': mutable,
        'b': _row(malformed, syncedAt: 'bad-number', owner: '  '),
        'c': {'url': 7},
        'https://extension.example.test/direct-only': 123,
      });

      expect(storage.getLibraryItemSyncedAccountUid(original), 'Owner A');
      // Mutation changes the stored string without allocating a new Map.
      final row = box.get('a') as Map;
      row['url'] = changed;
      row['animeWitcherSyncedUid'] = 'Owner B';
      expect(storage.getLibraryItemSyncedAccountUid(changed), 'Owner B');
      expect(storage.getLibraryItemUpdatedAt(malformed), 10);
      expect(storage.getLibraryItemSyncedAt(' $malformed '), 0);
      expect(storage.getLibraryItemSyncedAccountUid(malformed), isNull);
      // Direct canonical-key lookup is intentionally checked before malformed rows.
      expect(
        storage.isInLibrary('https://extension.example.test/direct-only'),
        isTrue,
      );
      expect(
        () => storage.isLibraryItemFavorite(original),
        throwsA(isA<TypeError>()),
      );
      await box.delete('c');
      expect(storage.isInLibrary(original), isFalse);
      expect(storage.isInLibrary(changed), isTrue);
      await box.clear();
      expect(storage.isInLibrary(changed), isFalse);
    },
  );
}

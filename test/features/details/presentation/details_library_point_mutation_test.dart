import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
// Match DetailsScreen's Material compatibility API.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

final class _Lookup {
  bool active = false;
  int posterReads = 0;
}

final class _Row extends MapBase<String, Object?> {
  _Row(this.fields, this.lookup);

  final Map<String, Object?> fields;
  final _Lookup lookup;

  @override
  Object? operator [](Object? key) {
    if (lookup.active && key == 'posterUrl') lookup.posterReads++;
    return fields[key];
  }

  @override
  void operator []=(String key, Object? value) => fields[key] = value;

  @override
  void clear() => fields.clear();

  @override
  Iterable<String> get keys => fields.keys;

  @override
  Object? remove(Object? key) => fields.remove(key);
}

final class _Storage extends StorageService {
  _Storage(DownloadPersistenceWorker worker, this.lookup, this.ioZone)
    : super(downloadPersistenceWorker: worker);

  final _Lookup lookup;
  final Zone ioZone;
  Future<void>? write;

  @override
  Future<void> setLibraryItemCategory(String url, String? category) {
    // Count the selected item's read, not the separate Hive write and screen
    // refresh. Each real card hydration reads its row's posterUrl once.
    lookup.active = false;
    // Run actual Hive I/O outside the widget test's fake async.
    final pending = ioZone.run(
      () => super.setLibraryItemCategory(url, category),
    );
    write = pending;
    return pending;
  }
}

final class _Account extends AnimeWitcherAccountService {
  _Account(StorageService storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  ({String url, bool keepFavorite})? removal;

  @override
  bool get isSignedIn => true;

  @override
  String get accountUid => 'test-account';

  @override
  Future<LibraryMembership?> fetchAnimeLibraryMembership(String url) async =>
      (category: LibraryCategory.watching, favorite: true);

  @override
  Future<int?> loadAnimeUserRating(String animeId) async => null;

  @override
  Future<void> removeLibraryItem(
    String itemUrl, {
    bool keepFavorite = false,
  }) async {
    removal = (url: itemUrl, keepFavorite: keepFavorite);
  }
}

final class _Details extends DetailsController {
  _Details(this.item);

  final MultimediaItem item;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData<MultimediaItem?>(item),
    episodes: const AsyncData<List<Episode>>(<Episode>[]),
    cast: const AsyncData<List<Actor>>(<Actor>[]),
    trailers: const AsyncData<List<Trailer>>(<Trailer>[]),
    related: const AsyncData<List<MultimediaItem>>(<MultimediaItem>[]),
    recommendations: const AsyncData<List<MultimediaItem>>(<MultimediaItem>[]),
    item: item,
    basicDetailsResolved: true,
    nextAiringResolved: true,
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
  }) async {}
}

void main() {
  testWidgets('Details removes a list entry without hydrating other cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    FlutterSecureStorage.setMockInitialValues({});

    const url = 'https://animewitcher.com/watch/selected';
    const legacy = ' HTTP://WWW.ANIMEWITCHER.COM/watch/selected/old?x=1 ';
    const provider = 'fixture-provider';
    final item = MultimediaItem(
      title: 'Selected anime',
      url: url,
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      provider: provider,
    );
    final lookup = _Lookup();

    late _Storage storage;
    late Box<dynamic> box;
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('aw-library-clear-');
      final previous = PathProviderPlatform.instance;
      final worker = DownloadPersistenceWorker.forDirectory(root.path);
      PathProviderPlatform.instance = _Paths(root.path);
      addTearDown(() async {
        await Hive.close();
        await worker.close();
        PathProviderPlatform.instance = previous;
        await root.delete(recursive: true);
      });
      storage = _Storage(worker, lookup, Zone.current);
      await storage.init();
      box = Hive.box<dynamic>(StorageService.kLibraryBox);
      await box.putAll({
        'a-legacy': _Row({
          'url': legacy,
          'title': 'First Hive winner',
          'provider': provider,
          'type': 'anime',
          'posterUrl': '',
          'updatedAt': 1,
          'libraryCategory': 'watching',
          'isFavorite': true,
        }, lookup),
        'b-duplicate': _Row({
          'url': url,
          'title': 'More recent duplicate',
          'type': 'manga',
          'posterUrl': '',
          'updatedAt': 100,
          'libraryCategory': 'notInterested',
          'isFavorite': false,
        }, lookup),
        for (var i = 0; i < 2400; i++)
          'z-library-$i': _Row({
            'url': 'https://example.test/library/$i',
            'title': 'Other title $i',
            'type': 'anime',
            'posterUrl': '',
            'updatedAt': i + 50,
            'libraryCategory': 'watching',
            'isFavorite': false,
          }, lookup),
      });
      expect(box.get('a-legacy'), isA<_Row>());
    });

    final account = _Account(storage);
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(requestOptions: options, error: 'Offline fixture'),
          ),
        ),
      );
    addTearDown(() => dio.close(force: true));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          dioClientProvider.overrideWithValue(dio),
          activeProviderProvider.overrideWithValue(null),
          detailsControllerProvider(detailsControllerKey(item))
              .overrideWith(() => _Details(item)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DetailsScreen(item: item),
                  ),
                ),
                child: const Text('Open selected anime'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open selected anime'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailsScreen), findsOneWidget);
    expect(find.text('أشاهده حاليًا'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    await tester.tap(find.text('أشاهده حاليًا'));
    await tester.pumpAndSettle();
    final removal = find.text('إزالة من القائمة');
    expect(removal, findsOneWidget);
    lookup.active = true;
    await tester.tap(removal);
    await tester.pumpAndSettle();
    expect(storage.write, isNotNull);
    await tester.runAsync(
      () => storage.write!.timeout(const Duration(seconds: 8)),
    );
    await tester.pumpAndSettle();

    expect(account.removal, (url: url, keepFavorite: true));
    expect(lookup.posterReads, 1);
    expect(lookup.active, isFalse);
    expect(storage.getLibraryItemCategory(url), isNull);
    expect(storage.isLibraryItemFavorite(url), isTrue);
    expect((box.get('a-legacy') as Map)['libraryCategory'], isNull);
    expect((box.get('b-duplicate') as Map)['libraryCategory'], 'notInterested');
    expect(box.length, 2402);
    expect(find.text('أضف لقائمة'), findsOneWidget);
    expect(find.text('أشاهده حاليًا'), findsNothing);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    Navigator.of(tester.element(find.byType(DetailsScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Open selected anime'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

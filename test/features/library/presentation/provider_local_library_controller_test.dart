import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/features/library/presentation/widgets/bookmarks_tab.dart';

class _Memory extends StorageService {
  final values = <String, String>{};
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  String getSelectedLibraryCategory() => 'watching';
  @override
  List<MultimediaItem> getLibraryItems({String? category}) => [
    MultimediaItem(title: 'Native', url: 'id', posterUrl: ''),
    MultimediaItem(title: 'Manga', url: 'manga', posterUrl: '', contentType: MultimediaContentType.manga),
  ];
}

class _Rift extends AnimeWitcherProvider {
  @override
  String get packageName => animeRiftProviderId;
  @override
  String get name => 'Anime Rift';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => ['ar'];
  @override
  Set<ProviderType> get supportedTypes => {ProviderType.anime};
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => [];
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => {};
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) async => [];
}

class _Native extends _Rift {
  @override
  String get packageName => 'com.fares669.animewitcher.native';
}

class _Mutable extends ActiveProvider {
  _Mutable(this.initial);
  final AnimeWitcherProvider initial;
  @override
  AnimeWitcherProvider? build() => initial;
  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

void main() {
  testWidgets('local library explains that it is not synced', (tester) async {
    final storage = _Memory();
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: SecureTokenStorage(storage),
    );
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(account),
        activeProviderProvider.overrideWithValue(_Rift()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('ar'),
          home: Scaffold(body: BookmarksTab()),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('مكتبة Anime Rift محفوظة على هذا الجهاز ولا تتم مزامنتها.'),
      findsOneWidget,
    );
    expect(find.text('تسجيل الدخول'), findsNothing);
  });

  test('switching library providers keeps each catalog isolated', () async {
    final storage = _Memory();
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: SecureTokenStorage(storage),
    );
    final rift = _Rift();
    final native = _Native();
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(account),
        activeProviderProvider.overrideWith(() => _Mutable(rift)),
      ],
    );
    addTearDown(container.dispose);
    final library = container.read(libraryProvider.notifier);
    final item = MultimediaItem(
      title: 'Rift',
      url: 'id',
      posterUrl: '',
      provider: animeRiftProviderId,
    );
    await library.addItem(item, category: LibraryCategory.watching);
    expect(library.itemsForCategory(LibraryMediaKind.anime, LibraryCategory.watching).single.title, 'Rift');
    expect(library.itemsForCategory(LibraryMediaKind.manga, LibraryCategory.watching).single.title, 'Manga');
    expect(
      (container.read(libraryProvider) as LibrarySuccess).items.single.title,
      'Rift',
    );
    await container.read(activeProviderProvider.notifier).set(native);
    expect(
      (container.read(libraryProvider) as LibrarySuccess).items.single.title,
      'Native',
    );
    expect(
      container
          .read(libraryProvider.notifier)
          .itemCategory('id', providerId: animeRiftProviderId),
      LibraryCategory.watching,
    );
    await container.read(activeProviderProvider.notifier).set(rift);
    expect(
      (container.read(libraryProvider) as LibrarySuccess).items.single.title,
      'Rift',
    );
  });

  test(
    'Rift library works signed out and never writes into native library',
    () async {
      final storage = _Memory();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          activeProviderProvider.overrideWithValue(_Rift()),
        ],
      );
      addTearDown(container.dispose);
      final item = MultimediaItem(
        title: 'Rift',
        url: 'id',
        posterUrl: '',
        provider: animeRiftProviderId,
      );
      final library = container.read(libraryProvider.notifier);
      await library.addItem(item, category: LibraryCategory.watching);
      await library.setFavorite(item, true);
      expect(library.isFavorite('id', providerId: animeRiftProviderId), isTrue);
      expect(
        library.itemCategory('id', providerId: animeRiftProviderId),
        LibraryCategory.watching,
      );
      expect(
        (container.read(libraryProvider) as LibrarySuccess).items.single.title,
        'Rift',
      );
    },
  );
}

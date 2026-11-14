import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_sync.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_screen.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _Storage extends MemoryStorageService {
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
  List<MultimediaItem> getLibraryItems({String? category}) => [];
}

class _NativeAccount extends AnimeWitcherAccountService {
  _NativeAccount(StorageService storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  int counts = 0;
  int pages = 0;

  @override
  bool get isSignedIn => true;
  @override
  String get accountUid => 'native-user';

  @override
  Future<Map<LibraryCategory, int>> fetchLibraryCounts({
    bool manga = false,
  }) async {
    counts++;
    return {LibraryCategory.watching: 1};
  }

  @override
  Future<AnimeWitcherLibraryPage> fetchLibraryPage({
    required LibraryCategory category,
    bool manga = false,
    AnimeWitcherLibraryCursor? cursor,
  }) async {
    pages++;
    return const AnimeWitcherLibraryPage(items: [], total: 0, nextCursor: null);
  }
}

class _RiftAccount extends AnimeRiftProvider {
  int counts = 0;
  int pages = 0;

  @override
  Future<bool> restoreAccountSession() async => true;

  @override
  Future<Map<String, int>> fetchCloudLibraryCounts() async {
    counts++;
    return {'my_list_currently_watching': 1};
  }

  @override
  Future<AnimeRiftCloudImportResult> importCloudLibraryCategory(
    StorageService storage,
    LibraryCategory category, {
    bool loadNextPage = false,
  }) async {
    pages++;
    return const AnimeRiftCloudImportResult(
      favorites: 0,
      categories: 0,
      history: 0,
      skipped: 0,
    );
  }
}

class _History extends WatchHistory {
  int requests = 0;

  @override
  List<HistoryItem> build() => [];

  @override
  Future<void> refreshFromServer() async {
    requests++;
  }
}

class _Active extends ActiveProvider {
  _Active(this.initial);
  final AnimeWitcherProvider? initial;

  @override
  AnimeWitcherProvider? build() => initial;

  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

void main() {
  setUp(AnimeRiftLocalAccountScope.reset);
  tearDown(AnimeRiftLocalAccountScope.reset);

  for (final riftSource in [false, true]) {
    testWidgets(
      '${riftSource ? 'Rift' : 'Witcher'} opening the library starts exactly one visible shelf request',
      (tester) async {
        if (riftSource) AnimeRiftLocalAccountScope.activate('linked-user');
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final storage = _Storage();
        final native = _NativeAccount(storage);
        final rift = _RiftAccount();
        final container = ProviderContainer(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            animeWitcherAccountServiceProvider.overrideWithValue(native),
            activeProviderProvider.overrideWithValue(riftSource ? rift : null),
            deviceProfileProvider.overrideWith(
              (ref) async => const DeviceProfile(),
            ),
            watchHistoryProvider.overrideWith(_History.new),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              locale: Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: LibraryScreen(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
        expect(riftSource ? rift.pages : native.pages, 1);
        // Native serves both anime/manga tabs; Rift gets its own anime overview.
        expect(riftSource ? rift.counts : native.counts, riftSource ? 1 : 2);
      },
    );

    for (final wide in [false, true]) {
      testWidgets(
        '${riftSource ? 'Rift' : 'Witcher'} mounted-but-hidden ${wide ? 'desktop' : 'phone'} library makes no network requests',
        (tester) async {
          AnimeRiftLocalAccountScope.activate('linked-user');
          tester.view.physicalSize = wide
              ? const Size(1200, 800)
              : const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          final storage = _Storage();
          final native = _NativeAccount(storage);
          final rift = _RiftAccount();
          final history = _History();
          final container = ProviderContainer(
            overrides: [
              storageServiceProvider.overrideWithValue(storage),
              animeWitcherAccountServiceProvider.overrideWithValue(native),
              activeProviderProvider.overrideWith(
                () => _Active(riftSource ? rift : null),
              ),
              deviceProfileProvider.overrideWith(
                (ref) async => const DeviceProfile(),
              ),
              watchHistoryProvider.overrideWith(() => history),
            ],
          );
          addTearDown(container.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const MaterialApp(
                locale: Locale('ar'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: TickerMode(enabled: false, child: LibraryScreen()),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 1));
          expect(native.pages + rift.pages, 0);
          expect(native.counts + rift.counts, 0);
          expect(history.requests, 0);

          // IndexedStack keeps this screen mounted when another tab is active.
          // Switching providers there must not quietly fetch hidden shelves.
          await container
              .read(activeProviderProvider.notifier)
              .set(riftSource ? null : rift);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 1));
          expect(native.pages + rift.pages, 0);
          expect(native.counts + rift.counts, 0);
          expect(history.requests, 0);
        },
      );
    }

    test(
      '${riftSource ? 'Rift' : 'Witcher'} library is network-idle until opened',
      () async {
        if (riftSource) AnimeRiftLocalAccountScope.activate('linked-user');
        final storage = _Storage();
        final native = _NativeAccount(storage);
        final rift = _RiftAccount();
        final container = ProviderContainer(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            animeWitcherAccountServiceProvider.overrideWithValue(native),
            activeProviderProvider.overrideWithValue(riftSource ? rift : null),
          ],
        );
        addTearDown(container.dispose);

        container.read(libraryProvider); // Details/account widgets may read it.
        await Future<void>.delayed(Duration.zero);
        expect(
          native.counts + rift.counts,
          0,
          reason: 'Constructing the library provider must not trigger network requests',
        );
        expect(native.pages + rift.pages, 0);

        await container
            .read(libraryProvider.notifier)
            .refreshVisibleFromServer(
              category: LibraryCategory.watching,
              mediaKind: LibraryMediaKind.anime,
            );
        await Future<void>.delayed(Duration.zero);
        expect(riftSource ? rift.pages : native.pages, 1);
        expect(riftSource ? rift.counts : native.counts, greaterThan(0));
      },
    );
  }
}

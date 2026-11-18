import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
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

class _History extends WatchHistory {
  int requests = 0;

  @override
  List<HistoryItem> build() => [];

  @override
  Future<void> refreshFromServer() async {
    requests++;
  }
}

void main() {
  testWidgets('opening the Witcher library loads only the visible shelf', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = _Storage();
    final native = _NativeAccount(storage);
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(native),
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
    expect(native.pages, 1);
    expect(native.counts, 2);
  });

  for (final wide in [false, true]) {
    testWidgets(
      'mounted but hidden Witcher ${wide ? 'desktop' : 'phone'} library stays offline',
      (tester) async {
        tester.view.physicalSize = wide
            ? const Size(1200, 800)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final storage = _Storage();
        final native = _NativeAccount(storage);
        final history = _History();
        final container = ProviderContainer(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            animeWitcherAccountServiceProvider.overrideWithValue(native),
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
        expect(native.pages, 0);
        expect(native.counts, 0);
        expect(history.requests, 0);
      },
    );
  }

  test('Witcher library is network-idle until opened', () async {
    final storage = _Storage();
    final native = _NativeAccount(storage);
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(native),
      ],
    );
    addTearDown(container.dispose);
    container.read(libraryProvider);
    await Future<void>.delayed(Duration.zero);
    expect(native.counts, 0);
    expect(native.pages, 0);

    await container
        .read(libraryProvider.notifier)
        .refreshVisibleFromServer(
          category: LibraryCategory.watching,
          mediaKind: LibraryMediaKind.anime,
        );
    await Future<void>.delayed(Duration.zero);
    expect(native.pages, 1);
    expect(native.counts, greaterThan(0));
  });
}

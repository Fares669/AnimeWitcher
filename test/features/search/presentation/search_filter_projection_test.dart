import 'dart:async';

import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/widgets/provider_search_filter_dialog.dart';
import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:animewitcher/features/search/presentation/search_provider.dart';
import 'package:animewitcher/features/search/presentation/search_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// Match the app's Material compatibility imports.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/memory_storage_service.dart';

class _LocalAnime extends WitanimeProvider {
  _LocalAnime()
    : super((uri, {cancelToken}) async {
        throw StateError('No network expected: $uri');
      });

  int optionsLoads = 0;

  Future<ProviderSearchFilterOptions> rawOptions() =>
      super.getSearchFilterOptions();

  @override
  Future<ProviderSearchFilterOptions> getSearchFilterOptions() {
    optionsLoads++;
    return rawOptions();
  }

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async => const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false);
}

class _LocalManga extends _LocalAnime {
  final availableOptions = Completer<ProviderSearchFilterOptions>();
  int mangaOptionsLoads = 0;

  @override
  String get packageName => 'fixture.manga';
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.manga};

  @override
  Future<ProviderSearchFilterOptions> getMangaSearchFilterOptions() {
    mangaOptionsLoads++;
    return availableOptions.future;
  }

  @override
  Future<ProviderMediaPage> searchMangaPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async => const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false);
}

class _Extensions extends ExtensionManager {
  _Extensions(this.providers);
  final List<AnimeWitcherProvider> providers;

  @override
  List<AnimeWitcherProvider> build() => providers;
}

void main() {
  testWidgets('Search filter badge, Reset and Apply use only offered choices', (
    tester,
  ) async {
    final oldPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.reset();
      debugDefaultTargetPlatformOverride = oldPlatform;
    });

    final anime = _LocalAnime();
    final manga = _LocalManga();
    final options = await anime.rawOptions();
    expect(options.studios.length, greaterThan(250));
    final selectedStudio = options.studios.last;
    final selectedGenre = options.genres.last;
    final initial = ProviderSearchFilters(
      statuses: {options.statuses.last},
      types: {options.types.last},
      ageRatings: {'not offered'},
      countries: {options.countries.last},
      years: {options.years.last},
      // No selected season, so Apply stays enabled as categories change.
      genres: {selectedGenre},
      tags: {'not offered'},
      studios: {selectedStudio, 'not offered'},
      sources: {options.sources.last},
      versions: {options.versions.last},
      sort: 'name_asc',
    );
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
        extensionManagerProvider.overrideWith(
          () => _Extensions([anime, manga]),
        ),
        activeProviderProvider.overrideWithValue(anime),
        deviceProfileProvider.overrideWith((_) async => const DeviceProfile()),
      ],
    );
    addTearDown(container.dispose);
    container.read(searchProviderFiltersProvider.notifier).set(initial);
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const SearchScreen())],
    );
    addTearDown(router.dispose);
    // Search can keep animating behind the sheet. Advance modal and chip
    // transitions without waiting for the whole route to cease painting.
    Future<void> settleModal() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await settleModal();

    final filter = find.byTooltip('الفلاتر');
    final apply = find.byKey(const ValueKey('filterApply'));
    final reset = find.byKey(const ValueKey('filterReset'));
    final dialog = find.byType(ProviderSearchFilterDialog);

    void expectCount(int count, {required bool resetEnabled}) {
      expect(tester.widget<TextButton>(reset).enabled, resetEnabled);
      expect(
        find.descendant(
          of: apply,
          matching: find.text(count > 0 ? 'تطبيق ($count)' : 'تطبيق'),
        ),
        findsOneWidget,
      );
      if (count > 0) {
        expect(
          find.descendant(of: dialog, matching: find.text('$count')),
          findsOneWidget,
        );
      }
    }

    await tester.tap(filter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.widget<ProviderSearchFilterDialog>(dialog).asSheet, isTrue);
    expect(anime.optionsLoads, 1);
    expectCount(8, resetEnabled: true);
    await settleModal();

    await tester.tap(find.byKey(const ValueKey('filterCategory-manga')));
    await tester.pump();
    expect(manga.mangaOptionsLoads, 1);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expectCount(8, resetEnabled: true);
    manga.availableOptions.complete(
      ProviderSearchFilterOptions(genres: [selectedGenre]),
    );
    await settleModal();
    expectCount(1, resetEnabled: true);

    await tester.tap(find.byKey(const ValueKey('filterCategory-characters')));
    await settleModal();
    expectCount(0, resetEnabled: false);
    await tester.tap(find.byKey(const ValueKey('filterCategory-manga')));
    await settleModal();
    expectCount(1, resetEnabled: true);
    expect(manga.mangaOptionsLoads, 1);
    await tester.tap(apply);
    await settleModal();
    expect(container.read(searchDomainProvider), SearchDomain.manga);
    final picked = container.read(searchProviderFiltersProvider);
    expect(picked.count, 1);
    expect(picked.genres, {selectedGenre});
    expect(picked.sort, 'name_asc');

    await tester.tap(filter);
    await settleModal();
    expectCount(1, resetEnabled: true);
    await tester.tap(reset);
    await settleModal();
    expectCount(0, resetEnabled: false);
    await tester.tap(apply);
    await settleModal();
    expect(container.read(searchProviderFiltersProvider).isEmpty, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

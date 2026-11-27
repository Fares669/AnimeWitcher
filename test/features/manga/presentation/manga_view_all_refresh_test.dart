import 'dart:async';
import 'dart:collection';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/widgets/home_section_header.dart';
import 'package:animewitcher/features/manga/presentation/manga_home_screen.dart';
import 'package:animewitcher/features/manga/presentation/manga_view_all_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Storage extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

MultimediaItem _manga(String title) => MultimediaItem(
  title: title,
  url: 'https://example.test/manga/${Uri.encodeComponent(title)}',
  posterUrl: '',
  contentType: MultimediaContentType.manga,
);

MangaLatestChapter _latest(String title) => MangaLatestChapter(
  manga: _manga(title),
  chapter: MangaChapter(
    id: title,
    mangaId: title,
    url: 'chapter://$title',
    name: 'Chapter 1',
  ),
);

class _CountedPage<T> extends ListBase<T> {
  _CountedPage(this._rows, this.onRead);

  final List<T> _rows;
  final void Function() onRead;

  @override
  int get length => _rows.length;

  @override
  T operator [](int index) {
    onRead();
    return _rows[index];
  }

  @override
  set length(int value) => throw UnsupportedError('immutable test data');

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('immutable test data');
}

class _Source extends AnimeWitcherNativeProvider {
  _Source({required this.latest})
    : super(Dio(), SettingsRepository(_Storage()));

  final bool latest;
  final requests = <int>[];
  final releaseOldPage = Completer<void>();
  int staleReads = 0;
  int _firstPageCount = 0;

  Future<MangaViewAllPage<T>> _load<T>({
    required bool selected,
    required int offset,
    required T Function(String title) make,
  }) async {
    if (!selected) {
      return (items: [make('Other featured')], nextOffset: 1, hasMore: false);
    }
    requests.add(offset);
    if (offset == 0) {
      final firstPage = ++_firstPageCount;
      final prefix = switch (firstPage) {
        1 => 'Home preview',
        2 => 'Old catalog',
        _ => 'Current catalog',
      };
      return (
        items: List.generate(6, (i) => make('$prefix $i'), growable: false),
        nextOffset: 6,
        hasMore: firstPage == 2,
      );
    }

    expect(offset, 6);
    await releaseOldPage.future;
    return (
      items: _CountedPage<T>(
        List.generate(30, (i) => make('Stale catalog $i'), growable: false),
        () => staleReads++,
      ),
      nextOffset: 36,
      hasMore: false,
    );
  }

  @override
  Future<ProviderMediaPage> searchMangaPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    final page = await _load(selected: !latest, offset: offset, make: _manga);
    return ProviderMediaPage(
      items: page.items,
      nextOffset: page.nextOffset,
      hasMore: page.hasMore,
    );
  }

  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) async {
    final page = await _load(selected: latest, offset: offset, make: _latest);
    return MangaLatestChapterPage(
      items: page.items,
      nextOffset: page.nextOffset,
      hasMore: page.hasMore,
    );
  }
}

class _Manager extends ExtensionManager {
  _Manager(this.source);
  final AnimeWitcherProvider source;

  @override
  List<AnimeWitcherProvider> build() => [source];
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
  expect(done(), isTrue);
}

void main() {
  for (final latest in [false, true]) {
    testWidgets(
      'Manga View All ignores the pre-refresh append (latest=$latest)',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = _Source(latest: latest);
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const MangaHomeScreen()),
            GoRoute(
              path: '/manga-details',
              builder: (_, state) {
                final item = (state.extra! as MangaDetailsRouteExtra).item;
                return Scaffold(body: Text('Opened ${item.title}'));
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              extensionManagerProvider.overrideWith(() => _Manager(source)),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () => find.byType(HomeViewAllButton).evaluate().length == 2,
        );
        expect(source.requests, [0]);
        await tester.tap(find.byType(HomeViewAllButton).at(latest ? 0 : 1));
        final all = latest
            ? find.byType(MangaViewAllScreen<MangaLatestChapter>)
            : find.byType(MangaViewAllScreen<MultimediaItem>);
        await _pumpUntil(tester, () => source.requests.contains(6));
        expect(all, findsOneWidget);
        await tester.pump(const Duration(milliseconds: 400));
        expect(source.requests, [0, 0, 6]);
        expect(find.text('Old catalog 0'), findsWidgets);
        final refresh = find.descendant(
          of: all,
          matching: find.byType(RefreshIndicator),
        );
        final refreshState = tester.state<RefreshIndicatorState>(refresh);
        final completion = refreshState.show();
        await _pumpUntil(
          tester,
          () => find.text('Current catalog 0').evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 350));
        await completion;
        expect(source.requests, [0, 0, 6, 0]);
        expect(find.text('Old catalog 0'), findsNothing);

        source.releaseOldPage.complete();
        await tester.pumpAndSettle();
        final staleVisible = find.text('Stale catalog 0').evaluate().isNotEmpty;
        final current = find.text('Current catalog 0').first;
        expect(current, findsOneWidget);
        await tester.tap(current);
        await tester.pumpAndSettle();
        expect(find.text('Opened Current catalog 0'), findsOneWidget);
        expect(source.requests, [0, 0, 6, 0]);

        expect(source.staleReads, 0);
        expect(staleVisible, isFalse);
      },
    );
  }
}

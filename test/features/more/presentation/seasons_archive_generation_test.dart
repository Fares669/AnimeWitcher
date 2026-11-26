import 'dart:async';
import 'dart:typed_data';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/seasons_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/anime_catalog_shimmer.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:animewitcher/shared/widgets/app_side_menu.dart';
import 'package:animewitcher/shared/widgets/phone_fixed_side_menu.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

const _menuOpen = ValueKey<String>('app-side-menu-button');
const _menuSeasons = ValueKey<String>('app-side-menu-page-seasons');
const _menuPanel = ValueKey<String>('app-side-menu');
const _current = 'صيف عام 2026';
const _archived = 'شتاء عام 2025';
const _otherTab = 'المواسم الأخرى';
const _currentTab = 'الحالي';
const _currentArticle = 'بطاقة الموسم الحالي';
const _archiveArticle = 'بطاقة الموسم السابق المختار';
final _screen = find.byType(SeasonsScreen);

final class _NoSockets implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw StateError('Unexpected test socket');
  }

  @override
  void close({bool force = false}) {}
}

final class _SignedOut extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

final class _Catalogue extends AnimeWitcherNativeProvider {
  _Catalogue(Dio dio, SettingsRepository settings, this._identity)
    : super(dio, settings);

  final String _identity;

  @override
  String get packageName => _identity;

  final configs = <Completer<AnimeWitcherSeasonConfig>>[];
  final archives = <Completer<List<String>>>[];
  final pageCalls = <(String, int, int)>[];
  final archiveRefreshFlags = <bool>[];

  @override
  Future<AnimeWitcherSeasonConfig> getSeasonConfig() {
    final operation = Completer<AnimeWitcherSeasonConfig>();
    configs.add(operation);
    return operation.future;
  }

  @override
  Future<List<String>> getAllSeasons({bool refresh = false}) {
    final operation = Completer<List<String>>();
    archives.add(operation);
    archiveRefreshFlags.add(refresh);
    return operation.future;
  }

  @override
  Future<ProviderMediaPage> getSeasonPage(
    String season, {
    int offset = 0,
    int limit = 30,
  }) async {
    pageCalls.add((season, offset, limit));
    return ProviderMediaPage(
      items: [
        MultimediaItem(
          url: 'https://fixture.invalid/item/${Uri.encodeComponent(season)}',
          title: season == _current
              ? _currentArticle
              : season == _archived
              ? _archiveArticle
              : 'بطاقة $season',
          posterUrl: '',
          catalogType: 'مسلسل',
        ),
      ],
      nextOffset: 1,
      hasMore: false,
    );
  }

  void finishConfig() => configs.last.complete(
    const AnimeWitcherSeasonConfig(
      past: 'ربيع عام 2026',
      current: _current,
      next: 'خريف عام 2026',
    ),
  );

  void finishArchive() =>
      archives.last.complete(const <String>[_archived, 'ربيع عام 2024']);
}

Finder _inside(Finder parent, Finder child) =>
    find.descendant(of: parent, matching: child);

void _expectVisibleCard(String season, String title) {
  final url = 'https://fixture.invalid/item/${Uri.encodeComponent(season)}';
  final card = find.byKey(ValueKey<String>('season-$season-$url')).hitTestable();
  expect(card, findsOneWidget);
  // A missing-poster tile and the caption can both show the same title.
  expect(_inside(card, find.text(title)).hitTestable(), findsWidgets);
}

Future<void> _frames(WidgetTester tester, {int count = 10}) async {
  // The deliberate held shimmer never settles on its own.
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_menuOpen));
  await tester.pumpAndSettle();
  final row = find.byKey(_menuSeasons);
  final sidebar = _inside(find.byKey(_menuPanel), find.byType(Scrollable)).first;
  for (var i = 0; i < 8 && row.hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(sidebar, const Offset(0, -245));
    await tester.pumpAndSettle();
  }
  expect(row.hitTestable(), findsOneWidget);
  await tester.tap(row.hitTestable());
  await _frames(tester);
  expect(_screen, findsOneWidget);
  expect(ModalRoute.of(tester.element(_screen)), isA<MaterialPageRoute<void>>());
  expect(Directionality.of(tester.element(_screen)), TextDirection.rtl);
}

Future<void> _selectTab(WidgetTester tester, String title) async {
  final label = _inside(_screen, find.widgetWithText(Tab, title));
  expect(label, findsOneWidget);
  if (label.hitTestable().evaluate().isEmpty) {
    // Scroll only the actual tab strip horizontally to expose its button.
    await tester.ensureVisible(label);
    await tester.pump();
  }
  expect(label.hitTestable(), findsOneWidget);
  await tester.tap(label.hitTestable());
  await _frames(tester);
}

final class _Selection extends ActiveProvider {
  _Selection(this.initial);
  final AnimeWitcherProvider initial;

  @override
  AnimeWitcherProvider? build() => initial;

  void choose(AnimeWitcherProvider next) => state = next;
}

final _year2025 = find.byKey(const ValueKey('other-season-year-2025'));
final _oldYear = find.byKey(const ValueKey('other-season-year-1971'));
const _localError = 'تعذر تحميل بيانات المواسم';

Future<void> _pullRefresh(WidgetTester tester) async {
  // Start below the actual header/tabs. Reload replaces the tab body with
  // its usual loading state, so count the provider demand, not a mock
  // callback or an indicator subtree that is being disposed.
  await tester.dragFrom(const Offset(195, 230), const Offset(0, 370));
  await _frames(tester);
}

Future<void> _pop(WidgetTester tester) async {
  final route = ModalRoute.of(tester.element(_screen))!;
  final budget = route.reverseTransitionDuration + const Duration(milliseconds: 240);
  await tester.tap(find.byType(AppBackButton).hitTestable().first);
  await tester.pump();
  expect(route.isCurrent, isFalse);
  final allScreens = find.byType(SeasonsScreen, skipOffstage: false);
  for (
    var elapsed = Duration.zero;
    elapsed < budget && allScreens.evaluate().isNotEmpty;
    elapsed += const Duration(milliseconds: 60)
  ) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(allScreens, findsNothing);
}

void main() {
  testWidgets('archive retry and fresh provider/config generations stay local', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = MemoryStorageService();
    final dio = Dio()..httpClientAdapter = _NoSockets();
    addTearDown(() => dio.close(force: true));
    final old = _Catalogue(dio, SettingsRepository(storage), 'fixture-archive-old');
    final current = _Catalogue(dio, SettingsRepository(storage), 'fixture-archive-current');
    final selection = _Selection(old);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          activeProviderProvider.overrideWith(() => selection),
          animeWitcherAccountControllerProvider.overrideWith(_SignedOut.new),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) => AppSideMenuShell(
              currentBranchIndex: TaskbarDestination.home.branchIndex,
              entries: phoneFixedSideMenuEntries(
                context,
                ref,
                currentBranchIndex: TaskbarDestination.home.branchIndex,
                onDestination: (_) {},
              ),
              destinations: const <TaskbarDestination>[],
              onDestination: (_) {},
              onAccount: () {},
              canOpen: () => true,
              canPopWhenClosed: false,
              onBackWhenClosed: () {},
              child: const Scaffold(body: Center(child: AppSideMenuButton())),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _open(tester);
    old.finishConfig();
    await _frames(tester);
    expect(old.archives, isEmpty);
    _expectVisibleCard(_current, _currentArticle);
    await _selectTab(tester, _otherTab);
    expect(old.archives, hasLength(1));
    expect(old.archives.single.isCompleted, isFalse);

    // Selection changes while the original archive and the new canonical
    // config are each held. The old result cannot appear in the new scope.
    selection.choose(current);
    await _frames(tester);
    expect(current.configs, hasLength(1));
    old.archives.single.complete(const <String>['شتاء عام 1971']);
    await _frames(tester);
    expect(_oldYear, findsNothing);
    expect(current.archives, isEmpty);
    current.finishConfig();
    await _frames(tester);
    expect(current.archives, hasLength(1));
    expect(_oldYear, findsNothing);
    expect(find.byType(AnimeCatalogShimmer), findsOneWidget);
    current.archives.single.completeError(StateError('synthetic archive failure'));
    await _frames(tester);
    expect(find.text(_localError).hitTestable(), findsOneWidget);

    // The archive error belongs to Archive; Current remains independently
    // usable and selecting Archive again doesn't retry invisibly.
    await _selectTab(tester, _currentTab);
    _expectVisibleCard(_current, _currentArticle);
    expect(current.pageCalls.where((call) => call.$1 == _current), [(_current, 0, 30)]);
    await _selectTab(tester, _otherTab);
    expect(find.text(_localError).hitTestable(), findsOneWidget);
    expect(current.archives, hasLength(1));
    final retry = find.widgetWithText(FilledButton, 'إعادة المحاولة').hitTestable();
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await _frames(tester);
    expect(current.configs, hasLength(2));
    current.finishConfig();
    await _frames(tester);
    expect(current.archives, hasLength(2));
    expect(_year2025, findsNothing);
    current.finishArchive();
    await _frames(tester);
    expect(_year2025.hitTestable(), findsOneWidget);

    // Actual Current refresh retains canonical config/page behavior without
    // requesting its now-unvisited Archive generation.
    await _selectTab(tester, _currentTab);
    // Archive Retry used the original whole bootstrap, so the first re-entry
    // to Current just loaded its second canonical page. Measure the pull
    // against that settled generation, not the earlier pre-Retry total.
    final beforeCurrentPull = current.pageCalls
        .where((call) => call.$1 == _current)
        .toList(growable: false);
    expect(beforeCurrentPull, [(_current, 0, 30), (_current, 0, 30)]);
    await _pullRefresh(tester);
    expect(current.configs, hasLength(3));
    expect(current.archives, hasLength(2));
    current.finishConfig();
    await _frames(tester);
    expect(current.archives, hasLength(2));
    _expectVisibleCard(_current, _currentArticle);
    expect(current.pageCalls.where((call) => call.$1 == _current),
        [...beforeCurrentPull, (_current, 0, 30)]);
    await _selectTab(tester, _otherTab);
    expect(current.archives, hasLength(3));
    current.finishArchive();
    await _frames(tester);
    expect(_year2025.hitTestable(), findsOneWidget);

    // Real Archive pull has its own loading and single post-config archive.
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 3);
    await _pullRefresh(tester);
    expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 3);
    expect(current.configs, hasLength(4));
    expect(current.archives, hasLength(3));
    current.finishConfig();
    await _frames(tester);
    expect(current.archives, hasLength(4));
    expect(_year2025, findsNothing);
    expect(find.byType(AnimeCatalogShimmer), findsOneWidget);
    current.finishArchive();
    await _frames(tester);
    expect(_year2025.hitTestable(), findsOneWidget);

    // A genuine account revision supersedes the held old refresh config:
    // settling it may not start a new Archive stage in the wrong generation.
    await _pullRefresh(tester);
    expect(current.configs, hasLength(5));
    final scope = ProviderScope.containerOf(tester.element(_screen), listen: false);
    scope.read(accountDataRevisionProvider.notifier).bump();
    await _frames(tester);
    expect(current.configs, hasLength(6));
    current.configs[4].complete(const AnimeWitcherSeasonConfig(
      past: 'ربيع عام 2026', current: _current, next: 'خريف عام 2026',
    ));
    await _frames(tester);
    expect(current.archives, hasLength(4));
    current.finishConfig();
    await _frames(tester);
    expect(current.archives, hasLength(5));
    current.finishArchive();
    await _frames(tester);
    expect(_year2025.hitTestable(), findsOneWidget);

    // Back during a held Archive refresh config prevents late archive start.
    await _pullRefresh(tester);
    expect(current.configs, hasLength(7));
    await _pop(tester);
    current.finishConfig();
    await tester.pumpAndSettle();
    expect(current.archives, hasLength(5));
    expect(current.archiveRefreshFlags, List<bool>.filled(5, false));
    expect(find.byKey(_menuOpen).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

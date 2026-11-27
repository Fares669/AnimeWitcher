import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/features/more/presentation/global_statistics_screen.dart';
import 'package:animewitcher/features/more/presentation/more_sidebar_shell.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

typedef _Request = ({
  AnimeWitcherGlobalRanking ranking,
  int offset,
  int limit,
  Completer<ProviderMediaPage> response,
});

final class _RankingProvider extends AnimeWitcherNativeProvider {
  _RankingProvider()
    : super(
        Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (request, handler) =>
                  handler.reject(DioException(requestOptions: request)),
            ),
          ),
        SettingsRepository(MemoryStorageService()),
      );

  final requests = <_Request>[];

  @override
  Future<ProviderMediaPage> getGlobalRankingPage(
    AnimeWitcherGlobalRanking ranking, {
    int offset = 0,
    int limit = animeWitcherRankingPageSize,
  }) {
    final response = Completer<ProviderMediaPage>();
    requests.add((
      ranking: ranking,
      offset: offset,
      limit: limit,
      response: response,
    ));
    return response.future;
  }
}

final class _MutableUrl extends MultimediaItem {
  _MutableUrl(this.current)
    : super(title: 'dynamic row', url: current, posterUrl: '');

  String current;

  @override
  String get url => current;
}

MultimediaItem _row(String title, {String? url, int? id}) => MultimediaItem(
  title: title,
  url: url ?? 'fixture-$title',
  posterUrl: '',
  tmdbId: id,
);

void _finish(
  _Request request,
  List<MultimediaItem> rows, {
  required bool more,
  int? nextOffset,
}) {
  request.response.complete(
    ProviderMediaPage(
      items: rows,
      nextOffset: nextOffset ?? request.offset + request.limit,
      hasMore: more,
    ),
  );
}

Future<void> _frames(WidgetTester tester, [int n = 5]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder _grid([
  AnimeWitcherGlobalRanking ranking = AnimeWitcherGlobalRanking.all,
]) => find.byKey(PageStorageKey<String>('global-ranking-${ranking.queryType}'));

ScrollPosition _position(
  WidgetTester tester, [
  AnimeWitcherGlobalRanking ranking = AnimeWitcherGlobalRanking.all,
]) => tester.widget<GridView>(_grid(ranking)).controller!.position;

SliverChildBuilderDelegate _delegate(
  WidgetTester tester, [
  AnimeWitcherGlobalRanking ranking = AnimeWitcherGlobalRanking.all,
]) =>
    tester.widget<GridView>(_grid(ranking)).childrenDelegate
        as SliverChildBuilderDelegate;

String _title(
  WidgetTester tester,
  int index, [
  AnimeWitcherGlobalRanking ranking = AnimeWitcherGlobalRanking.all,
]) =>
    (_delegate(tester, ranking).builder(tester.element(_grid(ranking)), index)!
            as MultimediaCard)
        .title;

Finder _visibleCard(String title) => find
    .byWidgetPredicate(
      (widget) => widget is MultimediaCard && widget.title == title,
    )
    .hitTestable();

Future<void> _choose(
  WidgetTester tester,
  AnimeWitcherGlobalRanking ranking,
) async {
  final tab = find.text(ranking.arabicTitle);
  if (tab.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(tab);
    await tester.pump();
  }
  await tester.tap(tab.hitTestable());
  await _frames(tester, 7);
}

Future<void> _mount(
  WidgetTester tester,
  Size size,
  _RankingProvider provider,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final screen = const GlobalStatisticsScreen();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [activeProviderProvider.overrideWithValue(provider)],
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: size.width > 700 ? MorePaneScope(child: screen) : screen,
      ),
    ),
  );
  await _frames(tester);
  expect(
    Directionality.of(tester.element(find.byType(GlobalStatisticsScreen))),
    TextDirection.rtl,
  );
}

void main() {
  for (final size in [const Size(390, 844), const Size(1260, 900)]) {
    testWidgets(
      'Arabic ranking appends 24 pages without reordering at ${size.width}',
      (tester) async {
        final provider = _RankingProvider();
        await _mount(tester, size, provider);
        expect(provider.requests, hasLength(1));
        final first = provider.requests.single;
        expect(
          (first.ranking, first.offset, first.limit),
          (AnimeWitcherGlobalRanking.all, 0, 24),
        );
        _finish(first, [
          _row('original trimmed winner', url: 'shared'),
          _row('first-page duplicate stays', url: ' shared '),
          _row('fallback identity', url: ' ', id: 42),
          for (var i = 3; i < 24; i++) _row('page 0 row $i'),
        ], more: true);
        await _frames(tester);
        expect(_title(tester, 0), 'original trimmed winner');
        expect(_title(tester, 1), 'first-page duplicate stays');
        expect(_title(tester, 2), 'fallback identity');

        const appended = 24;
        for (var page = 1; page <= appended; page++) {
          final position = _position(tester);
          position.jumpTo(position.maxScrollExtent);
          await _frames(tester, 2);
          final calendarRequests = provider.requests
              .where(
                (request) => request.ranking == AnimeWitcherGlobalRanking.all,
              )
              .toList();
          expect(calendarRequests, hasLength(page + 1));
          final request = calendarRequests.last;
          expect(
            (request.ranking, request.offset, request.limit),
            (AnimeWitcherGlobalRanking.all, page * 24, 24),
          );
          _finish(request, [
            _row('must not replace original', url: ' shared '),
            _row('fallback identity', url: '', id: 42),
            for (var i = 0; i < 22; i++) _row('page $page row $i'),
          ], more: page < appended);
          await _frames(tester, 3);
          expect(_delegate(tester).estimatedChildCount, 24 + 22 * page);
          expect(_title(tester, 24 + 22 * (page - 1)), 'page $page row 0');
          expect(_title(tester, 23 + 22 * page), 'page $page row 21');
          if (page == 12) {
            await _choose(tester, AnimeWitcherGlobalRanking.continuing);
            final other = provider.requests.last;
            expect(other.ranking, AnimeWitcherGlobalRanking.continuing);
            expect(other.offset, 0);
            _finish(other, [_row('secondary tab only')], more: false);
            await _frames(tester);
            expect(_visibleCard('secondary tab only'), findsOneWidget);
            await _choose(tester, AnimeWitcherGlobalRanking.all);
            expect(_position(tester), same(position));
            expect(_delegate(tester).estimatedChildCount, 24 + 22 * page);
          }
        }
        final position = _position(tester);
        position.jumpTo(position.maxScrollExtent);
        await _frames(tester);
        expect(_visibleCard('page 24 row 21'), findsOneWidget);
        expect(provider.requests, hasLength(appended + 2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'deep ranking resets keys on page-zero and honors a mutable provider row',
    (tester) async {
      final provider = _RankingProvider();
      await _mount(tester, const Size(390, 844), provider);
      final original = provider.requests.single;
      _finish(original, [
        for (var i = 0; i < 24; i++) _row('first generation $i'),
      ], more: true);
      await _frames(tester);
      for (var page = 1; page <= 4; page++) {
        final position = _position(tester);
        position.jumpTo(position.maxScrollExtent);
        await _frames(tester, 2);
        _finish(provider.requests.last, [
          for (var n = 0; n < 24; n++) _row('discarded $page-$n'),
        ], more: true);
        await _frames(tester, 3);
      }

      final saved = _position(tester);
      saved.jumpTo(0);
      await _frames(tester);
      await tester.dragFrom(const Offset(195, 245), const Offset(0, 365));
      await _frames(tester);
      final refresh = provider.requests.last;
      expect(refresh.offset, 0);
      final mutable = _MutableUrl('dynamic before');
      _finish(refresh, [
        mutable,
        for (var i = 1; i < 24; i++) _row('refreshed $i'),
      ], more: true);
      await _frames(tester);
      expect(_delegate(tester).estimatedChildCount, 24);
      for (var page = 1; page <= 4; page++) {
        saved.jumpTo(saved.maxScrollExtent);
        await _frames(tester, 2);
        final request = provider.requests.last;
        expect(request.offset, page * 24);
        _finish(request, [
          for (var n = 0; n < 24; n++) _row('current $page-$n'),
        ], more: true);
        await _frames(tester, 3);
      }

      mutable.current = 'dynamic after';
      saved.jumpTo(saved.maxScrollExtent);
      await _frames(tester, 2);
      final last = provider.requests.last;
      expect(last.offset, 120);
      _finish(
        last,
        [
          _row(
            'reuse removed page-zero key',
            url: 'fixture-first generation 0',
          ),
          _row('reuse pre-mutation key', url: 'dynamic before'),
          _row('duplicate mutated key', url: ' dynamic after '),
        ],
        more: true,
        nextOffset: last.offset,
      );
      await _frames(tester, 3);
      expect(_delegate(tester).estimatedChildCount, 122);
      expect(_title(tester, 120), 'reuse removed page-zero key');
      expect(_title(tester, 121), 'reuse pre-mutation key');
      saved.jumpTo(saved.maxScrollExtent);
      await _frames(tester);
      expect(provider.requests.last, same(last));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short ranking keeps retry, page-zero refresh, tabs and generation isolation',
    (tester) async {
      final provider = _RankingProvider();
      await _mount(tester, const Size(390, 844), provider);
      final original = provider.requests.single;
      _finish(original, [
        for (var i = 0; i < 22; i++) _row('old initial $i'),
      ], more: true);
      await _frames(tester);
      final saved = _position(tester);
      saved.jumpTo(saved.maxScrollExtent);
      await _frames(tester, 2);
      final failed = provider.requests.last;
      expect(failed.offset, 24);
      failed.response.completeError(StateError('local fixture append'));
      await _frames(tester);
      final retry = find
          .widgetWithText(TextButton, 'إعادة المحاولة')
          .hitTestable();
      expect(retry, findsOneWidget);
      await tester.tap(retry);
      await _frames(tester, 2);
      expect(provider.requests.last.offset, 24);
      _finish(provider.requests.last, [_row('old last')], more: false);
      await _frames(tester);
      expect(_delegate(tester).estimatedChildCount, 23);

      await _choose(tester, AnimeWitcherGlobalRanking.continuing);
      final continuing = provider.requests.last;
      expect(
        (continuing.ranking, continuing.offset),
        (AnimeWitcherGlobalRanking.continuing, 0),
      );
      _finish(continuing, [_row('continuing only')], more: false);
      await _frames(tester);
      expect(_visibleCard('continuing only'), findsOneWidget);
      await _choose(tester, AnimeWitcherGlobalRanking.all);
      expect(provider.requests, hasLength(4));
      expect(_position(tester), same(saved));
      saved.jumpTo(0);
      await _frames(tester);
      await tester.dragFrom(const Offset(195, 245), const Offset(0, 365));
      await _frames(tester);
      final refresh = provider.requests.last;
      expect(
        (refresh.ranking, refresh.offset),
        (AnimeWitcherGlobalRanking.all, 0),
      );
      _finish(refresh, [
        for (var i = 0; i < 22; i++) _row('refreshed $i'),
      ], more: true);
      await _frames(tester);
      expect(_title(tester, 0), 'refreshed 0');
      saved.jumpTo(saved.maxScrollExtent);
      await _frames(tester);
      final pendingAppend = provider.requests.last;
      expect(pendingAppend.offset, 24);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(GlobalStatisticsScreen)),
      );
      container.read(accountDataRevisionProvider.notifier).bump();
      await _frames(tester);
      final revised = provider.requests.lastWhere(
        (request) =>
            request.ranking == AnimeWitcherGlobalRanking.all &&
            request.offset == 0,
      );
      expect(
        (revised.ranking, revised.offset),
        (AnimeWitcherGlobalRanking.all, 0),
      );
      _finish(pendingAppend, [_row('stale result')], more: false);
      _finish(revised, [
        _row('old last', url: 'fixture-refreshed generation'),
      ], more: false);
      await _frames(tester);
      expect(_delegate(tester).estimatedChildCount, 1);
      expect(_title(tester, 0), 'old last');
      expect(find.text('stale result'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

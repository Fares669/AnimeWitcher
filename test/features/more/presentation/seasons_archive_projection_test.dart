import 'dart:collection';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/features/more/presentation/seasons_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _archivesTab = 'المواسم الأخرى';
const _currentTab = 'الحالي';
const _archiveChoice = 'صيف\tعام 2029';
const _oldYearKey = ValueKey('other-season-year-2029');
const _newYearKey = ValueKey('other-season-year-2030');
const _detailsIdentity = ValueKey('archive-details-url');

final class _CountingTitles extends ListBase<String> {
  _CountingTitles(this.values);
  final List<String> values;
  int titleReads = 0;

  @override
  int get length => values.length;

  @override
  set length(int value) => throw UnsupportedError('fixture is immutable');

  @override
  String operator [](int index) {
    titleReads++;
    return values[index];
  }

  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('fixture is immutable');
}

final class _ArchiveProvider extends WitanimeProvider {
  _ArchiveProvider(this.archives)
    : super((uri, {cancelToken}) async => throw StateError('Unexpected $uri'));

  final List<_CountingTitles> archives;
  final queriedSeasons = <String>[];
  int archiveRequests = 0;
  int configRequests = 0;

  @override
  Future<ProviderSeasonConfig> getSeasonConfig() async {
    configRequests++;
    return const ProviderSeasonConfig(
      past: 'ربيع عام 2026',
      current: 'صيف عام 2026',
      next: 'خريف عام 2026',
    );
  }

  @override
  Future<List<String>> getAllSeasons({bool refresh = false}) async =>
      archives[archiveRequests++];

  @override
  Future<ProviderMediaPage> getSeasonPage(
    String season, {
    int offset = 0,
    int limit = 30,
  }) async {
    queriedSeasons.add(season);
    return ProviderMediaPage(
      items: [
        MultimediaItem(
          title: 'Fixture $season',
          url: 'https://fixture.invalid/item/${Uri.encodeComponent(season)}',
          posterUrl: '',
        ),
      ],
      nextOffset: 1,
      hasMore: false,
    );
  }
}

Future<void> _tapTab(WidgetTester tester, String label) async {
  final tab = find.widgetWithText(Tab, label);
  if (tab.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(tab);
    await tester.pump();
  }
  await tester.tap(tab.hitTestable());
  await tester.pumpAndSettle();
}

Finder _row(int year) => find
    .ancestor(
      of: find.byKey(ValueKey('other-season-year-$year')),
      matching: find.byType(Column),
    )
    .first;

Finder _button(int year, String season) => find.descendant(
  of: _row(year),
  matching: find.widgetWithText(FilledButton, season),
);

void main() {
  for (final size in [const Size(390, 844), const Size(1260, 900)]) {
    testWidgets(
      'archive retains its parsed ordering on an Arabic ${size.width} route',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final initial = _CountingTitles([
          for (var year = 1900; year < 2029; year++)
            for (final season in ['ربيع', 'شتاء', 'خريف', 'صيف'])
              '$season عام $year',
          'شتاء عام 21000',
          'صيف عام 2029',
          '  $_archiveChoice  ',
          'not a season',
          'خريف عام 2028 ده',
          'ربيع عام ٢٠٣٠',
        ]);
        final refreshed = _CountingTitles(['  خريف عام 2030  ', 'bad value']);
        final provider = _ArchiveProvider([initial, refreshed]);
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, _) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => context.push('/seasons'),
                    child: const Text('افتح المواسم'),
                  ),
                ),
              ),
            ),
            GoRoute(path: '/seasons', builder: (_, _) => const SeasonsScreen()),
            GoRoute(
              path: '/details',
              builder: (_, state) {
                final item = (state.extra! as DetailsRouteExtra).item;
                return Scaffold(
                  appBar: AppBar(),
                  body: Text(item.url, key: _detailsIdentity),
                );
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [activeProviderProvider.overrideWithValue(provider)],
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        );
        await tester.tap(find.text('افتح المواسم'));
        await tester.pumpAndSettle();
        expect(
          Directionality.of(tester.element(find.byType(SeasonsScreen))),
          TextDirection.rtl,
        );
        expect(provider.configRequests, 1);
        expect(provider.archiveRequests, 0);
        expect(initial.titleReads, 0);

        await _tapTab(tester, _archivesTab);
        expect(initial.titleReads, initial.length);
        expect(provider.archiveRequests, 1);
        expect(find.byKey(_oldYearKey).hitTestable(), findsOneWidget);
        expect(find.byKey(_newYearKey), findsNothing);
        final newest = tester.getTopLeft(find.byKey(_oldYearKey));
        final following = tester.getTopLeft(
          find.byKey(const ValueKey('other-season-year-2028')),
        );
        expect(newest.dy, lessThan(following.dy));
        final winter = _button(2029, 'شتاء');
        final summer = _button(2029, 'صيف');
        expect(tester.widget<FilledButton>(winter).onPressed, isNull);
        expect(tester.widget<FilledButton>(summer).onPressed, isNotNull);
        expect(
          tester.getCenter(winter).dx,
          greaterThan(tester.getCenter(summer).dx),
        );

        final readsOnEntry = initial.titleReads;
        for (var revisit = 0; revisit < 4; revisit++) {
          await _tapTab(tester, _currentTab);
          expect(find.byKey(_oldYearKey).hitTestable(), findsNothing);
          await _tapTab(tester, _archivesTab);
          expect(find.byKey(_oldYearKey).hitTestable(), findsOneWidget);
        }
        final extraReads = initial.titleReads - readsOnEntry;
        expect(extraReads, 0);
        expect(provider.archiveRequests, 1);

        await tester.tap(_button(2029, 'صيف').hitTestable());
        await tester.pumpAndSettle();
        expect(provider.queriedSeasons.last, _archiveChoice);
        final url =
            'https://fixture.invalid/item/${Uri.encodeComponent(_archiveChoice)}';
        final card = find.byKey(ValueKey('season-$_archiveChoice-$url'));
        await tester.tap(card.hitTestable());
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(find.byKey(_detailsIdentity)).data, url);
        router.pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byType(AppBackButton).hitTestable());
        await tester.pumpAndSettle();
        expect(find.byKey(_oldYearKey).hitTestable(), findsOneWidget);

        await tester.dragFrom(
          Offset(size.width / 2, 220),
          const Offset(0, 365),
        );
        await tester.pumpAndSettle();
        expect(provider.configRequests, 2);
        expect(provider.archiveRequests, 2);
        expect(refreshed.titleReads, refreshed.length);
        expect(find.byKey(_oldYearKey), findsNothing);
        expect(find.byKey(_newYearKey).hitTestable(), findsOneWidget);
        expect(
          tester.widget<FilledButton>(_button(2030, 'خريف')).onPressed,
          isNotNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

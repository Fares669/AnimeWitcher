import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/features/more/presentation/broadcast_schedule_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Request = ({
  String day,
  int offset,
  bool refresh,
  CancelToken? token,
  Completer<ProviderMediaPage> response,
});

final class _ScheduleProvider extends WitanimeProvider {
  _ScheduleProvider()
    : super((uri, {cancelToken}) async => throw StateError('Unexpected $uri'));

  final calls = <_Request>[];

  @override
  Future<ProviderMediaPage> getBroadcastSchedulePage(
    String day, {
    int offset = 0,
    int limit = 30,
    bool refresh = false,
    CancelToken? cancelToken,
  }) {
    final response = Completer<ProviderMediaPage>();
    calls.add((
      day: day,
      offset: offset,
      refresh: refresh,
      token: cancelToken,
      response: response,
    ));
    return response.future;
  }

  void finish(_Request request, String version) => request.response.complete(
    ProviderMediaPage(
      items: [
        for (var index = 0; index < 12; index++)
          MultimediaItem(
            title: '${request.day} $version $index',
            url:
                'https://fixture.invalid/${index + animeWitcherBroadcastDays.indexOf(request.day) * 100}',
            posterUrl: '',
          ),
      ],
      nextOffset: 12,
      hasMore: false,
    ),
  );
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _choose(WidgetTester tester, String day) async {
  final tab = find.widgetWithText(Tab, day);
  if (tab.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(tab);
    await tester.pump();
  }
  await tester.tap(tab.hitTestable());
  await _frames(tester);
}

void main() {
  for (final size in [const Size(390, 844), const Size(1260, 900)]) {
    testWidgets(
      'unrelated day responses leave visible Arabic cards stable at ${size.width}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final provider = _ScheduleProvider();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [activeProviderProvider.overrideWithValue(provider)],
            child: const MaterialApp(
              locale: Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: BroadcastScheduleScreen(),
            ),
          ),
        );
        await _frames(tester);
        final screen = find.byType(BroadcastScheduleScreen);
        expect(Directionality.of(tester.element(screen)), TextDirection.rtl);
        final container = ProviderScope.containerOf(tester.element(screen));
        final initial = provider.calls.single;
        final primaryDay = initial.day;
        final primaryIndex = animeWitcherBroadcastDays.indexOf(primaryDay);
        final secondaryDay =
            animeWitcherBroadcastDays[primaryIndex == 0 ? 1 : primaryIndex - 1];
        await _choose(tester, secondaryDay);
        expect(provider.calls, hasLength(2));
        expect(provider.calls.last.day, secondaryDay);
        provider.finish(provider.calls.last, 'secondary');
        await tester.pumpAndSettle();

        final secondaryCards = find.byType(MultimediaCard).hitTestable();
        final before = tester
            .widgetList<MultimediaCard>(secondaryCards)
            .toList();
        final beforeElements = secondaryCards.evaluate().toList();
        expect(before, isNotEmpty);
        provider.finish(initial, 'initial');
        await tester.pumpAndSettle();
        final after = tester
            .widgetList<MultimediaCard>(secondaryCards)
            .toList();
        expect(
          secondaryCards.evaluate().toList(),
          orderedEquals(beforeElements),
        );
        expect(after, hasLength(before.length));
        final replacements = [
          for (var i = 0; i < before.length; i++)
            if (!identical(before[i], after[i])) i,
        ].length;
        expect(replacements, 0);
        expect(provider.calls, hasLength(2));
        expect(
          find.text('$secondaryDay secondary 0').hitTestable(),
          findsWidgets,
        );

        await _choose(tester, primaryDay);
        expect(find.text('$primaryDay initial 0').hitTestable(), findsWidgets);
        expect(provider.calls, hasLength(2));

        // Actual pull uses the retained day page, not a rebuilt/stale one.
        await tester.dragFrom(
          Offset(size.width / 2, 225),
          const Offset(0, 365),
        );
        await _frames(tester);
        final pendingRefresh = provider.calls.last;
        expect(provider.calls, hasLength(3));
        expect(
          (pendingRefresh.day, pendingRefresh.offset, pendingRefresh.refresh),
          (primaryDay, 0, true),
        );

        // A schedule-source invalidation replaces the selected day only; the
        // superseded callback cannot publish old cards after changing scope.
        container.read(accountDataRevisionProvider.notifier).bump();
        await _frames(tester);
        expect(provider.calls, hasLength(4));
        expect(pendingRefresh.token!.isCancelled, isTrue);
        provider.finish(pendingRefresh, 'superseded');
        provider.finish(provider.calls.last, 'fresh');
        await tester.pumpAndSettle();
        expect(find.text('$primaryDay superseded 0'), findsNothing);
        expect(find.text('$primaryDay fresh 0').hitTestable(), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

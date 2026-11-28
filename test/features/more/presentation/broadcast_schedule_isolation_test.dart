import 'dart:async';

import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

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
  _addAppendCase();
  _addAppendCase(changeMetadata: true);
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

Future<String> _rgbaHash(WidgetTester tester, GlobalKey shotKey) async =>
    (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(shotKey),
      );
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData())!;
        return sha256
            .convert(
              bytes.buffer.asUint8List(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ),
            )
            .toString();
      } finally {
        image.dispose();
      }
    }))!;

Map<String, MultimediaCard> _visibleCards(WidgetTester tester) => {
  for (final card in tester.widgetList<MultimediaCard>(
    find.byType(MultimediaCard).hitTestable(),
  ))
    card.heroTag: card,
};

({int common, int replacements}) _compareUnchanged(
  Map<String, MultimediaCard> before,
  Map<String, MultimediaCard> after,
) {
  var common = 0;
  var replacements = 0;
  for (final entry in before.entries) {
    final next = after[entry.key];
    if (next == null ||
        entry.value.title != next.title ||
        entry.value.catalogRating?.score != next.catalogRating?.score) {
      continue;
    }
    common++;
    if (!identical(entry.value, next)) replacements++;
  }
  return (common: common, replacements: replacements);
}

void _answer(
  _Request request,
  Iterable<int> indices, {
  required String title,
  required int nextOffset,
  required bool hasMore,
  Map<int, Map<String, String>>? syncData,
}) {
  request.response.complete(
    ProviderMediaPage(
      items: [
        for (final index in indices)
          MultimediaItem(
            title: '$title $index',
            url: 'https://fixture.invalid/${request.day}/$index',
            posterUrl: '',
            syncData: syncData?[index],
          ),
      ],
      nextOffset: nextOffset,
      hasMore: hasMore,
    ),
  );
}

void _addAppendCase({bool changeMetadata = false}) {
  testWidgets(
    changeMetadata
        ? 'loaded Arabic schedule rereads mutable artwork and rating inputs'
        : 'loaded Arabic schedule keeps unchanged cards through appends',
    (tester) async {
      const size = Size(390, 844);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await (FontLoader('ScheduleFixtureArabic')..addFont(
            rootBundle.load('assets/fonts/readex_pro/ReadexPro-Regular.ttf'),
          ))
          .load();
      final provider = _ScheduleProvider();
      final shotKey = GlobalKey();
      final hashes = <String>[];
      Future<void> snapshot() async {
        hashes.add(await _rgbaHash(tester, shotKey));
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [activeProviderProvider.overrideWithValue(provider)],
          child: MaterialApp(
            locale: const Locale('ar'),
            theme: ThemeData(fontFamily: 'ScheduleFixtureArabic'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => RepaintBoundary(
                        key: shotKey,
                        child: const BroadcastScheduleScreen(),
                      ),
                    ),
                  ),
                  child: const Text('افتح الجدول'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('افتح الجدول'));
      await _frames(tester);
      final screen = find.byType(BroadcastScheduleScreen);
      expect(Directionality.of(tester.element(screen)), TextDirection.rtl);
      final day = provider.calls.single.day;
      final dayIndex = animeWitcherBroadcastDays.indexOf(day);
      final other = animeWitcherBroadcastDays[dayIndex == 0 ? 1 : dayIndex - 1];
      final syncData = changeMetadata
          ? {
              for (var i = 0; i < 24; i++)
                i: <String, String>{'awMalScore': '7.1', 'malId': '77'},
            }
          : null;
      _answer(
        provider.calls.single,
        List.generate(24, (i) => i),
        title: 'الموعد',
        nextOffset: 24,
        hasMore: true,
        syncData: syncData,
      );
      await tester.pumpAndSettle();
      expect(find.text('الموعد 0').hitTestable(), findsWidgets);
      await snapshot();

      final grid = find.byKey(PageStorageKey<String>('broadcast-$day'));
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find.descendant(of: grid, matching: find.byType(Scrollable)),
          )
          .position;
      final scroll = position();
      expect(scroll.maxScrollExtent, greaterThan(390));
      scroll.jumpTo(scroll.maxScrollExtent - 385);
      await tester.pump();
      expect(provider.calls, hasLength(1));
      final before = _visibleCards(tester);
      final duplicateId = int.parse(before.values.last.title.split(' ').last);
      final duplicateKey = before.values.last.heroTag;

      final appendOffset = scroll.maxScrollExtent - 345;
      scroll.jumpTo(appendOffset);
      await tester.pump();
      expect(provider.calls, hasLength(2));
      final append = provider.calls.last;
      expect((append.day, append.offset, append.refresh), (day, 24, false));
      final pending = _visibleCards(tester);
      final unchangedPending = _compareUnchanged(before, pending);
      String? changedKey;
      if (syncData != null) {
        final cards = pending.values.toList();
        final changed = cards[cards.length ~/ 2];
        expect(changed.heroTag, isNot(duplicateKey));
        expect(changed.catalogRating?.score, 7.1);
        expect(changed.malId, 77);
        final index = int.parse(changed.title.split(' ').last);
        syncData[index]!['awMalScore'] = '9.3';
        syncData[index]!['malId'] = '88';
        changedKey = changed.heroTag;
      }

      _answer(
        append,
        [duplicateId, for (var i = 24; i < 36; i++) i],
        title: 'الموعد الجديد',
        nextOffset: 36,
        hasMore: false,
      );
      await tester.pumpAndSettle();
      final after = _visibleCards(tester);
      final unchangedAfter = _compareUnchanged(pending, after);
      expect(after[duplicateKey]?.title, 'الموعد الجديد $duplicateId');
      expect(after[duplicateKey], isNot(same(pending[duplicateKey])));
      if (changedKey != null) {
        expect(after[changedKey]?.catalogRating?.score, 9.3);
        expect(after[changedKey]?.malId, 88);
      }
      expect(unchangedPending.common, greaterThan(3));
      expect(unchangedAfter.common, greaterThan(3));
      // Candidate expectation. The exact stock arm uses the same witness with
      // the expectations for the original card replacement behavior.
      expect(unchangedPending.replacements, 0);
      expect(unchangedAfter.replacements, 0);
      expect(position().pixels, closeTo(appendOffset, 0.1));
      await snapshot();

      position().jumpTo(position().maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('الموعد الجديد 35').hitTestable(), findsWidgets);
      final lastOffset = position().pixels;
      await _choose(tester, other);
      expect(provider.calls, hasLength(3));
      _answer(
        provider.calls.last,
        [0, 1, 2],
        title: 'اليوم الآخر',
        nextOffset: 3,
        hasMore: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('اليوم الآخر 0').hitTestable(), findsWidgets);
      await _choose(tester, day);
      expect(provider.calls, hasLength(3));
      expect(position().pixels, closeTo(lastOffset, 0.1));
      await snapshot();

      position().jumpTo(0);
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(195, 250), const Offset(0, 365));
      await _frames(tester);
      expect(provider.calls, hasLength(4));
      final refresh = provider.calls.last;
      expect((refresh.day, refresh.offset, refresh.refresh), (day, 0, true));
      _answer(
        refresh,
        [0, 1, 2],
        title: 'بعد التحديث',
        nextOffset: 3,
        hasMore: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('بعد التحديث 0').hitTestable(), findsWidgets);
      await snapshot();

      debugPrint(
        'C21_SCHEDULE pending=${unchangedPending.replacements}/${unchangedPending.common} '
        'append=${unchangedAfter.replacements}/${unchangedAfter.common} '
        'rgba=${hashes.join(',')}',
      );
      await tester.tap(find.byType(AppBackButton).hitTestable().last);
      await tester.pumpAndSettle();
      expect(find.text('افتح الجدول'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/features/home/presentation/view_all_screen.dart';
import 'package:animewitcher/features/home/presentation/widgets/media_horizontal_list.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

ProviderMediaPage _page(List<MultimediaItem> items, {bool hasMore = false}) {
  return ProviderMediaPage(
    items: items,
    nextOffset: items.length,
    hasMore: hasMore,
  );
}

MultimediaItem _item(String title, String id) {
  return MultimediaItem(
    title: title,
    url: 'https://animewitcher.com/watch/$id',
    posterUrl: '',
  );
}

void main() {
  Future<void> pumpSeeded(
    WidgetTester tester,
    Future<ProviderMediaPage> Function(int) load,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ViewAllScreen(
          title: 'رائج الآن',
          initialMediaList: [
            for (var i = 0; i < 10; i++) _item('Anime $i', '$i'),
          ],
          initialOffset: 10,
          category: ViewAllCategory.providerContent,
          loadPage: load,
          forcePortrait: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> scrollToBottom(WidgetTester tester) async {
    final grid = tester.widget<GridView>(find.byType(GridView));
    grid.controller!.jumpTo(grid.controller!.position.maxScrollExtent);
    await tester.pump();
  }

  for (final title in ['الأفضل', 'رائج الآن', 'الأكثر مشاهدة']) {
    testWidgets('Home View all keeps the seeded cursor for $title', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final offsets = <int>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: MediaHorizontalList(
                title: title,
                mediaList: [
                  for (var i = 0; i < 10; i++) _item('Anime $i', '$i'),
                ],
                category: ViewAllCategory.providerContent,
                forcePortrait: true,
                initialViewAllOffset: 10,
                loadViewAllPage: (offset) async {
                  offsets.add(offset);
                  return ProviderMediaPage(
                    items: [_item('Next anime', 'next')],
                    nextOffset: 20,
                    hasMore: false,
                  );
                },
              ),
            ),
          ),
          GoRoute(
            path: '/view-all',
            builder: (context, state) =>
                ViewAllRoute($extra: state.extra! as ViewAllRouteExtra)
                    .build(context, state),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
      await tester.tap(find.text('عرض الكل'));
      await tester.pumpAndSettle();
      expect(find.byType(ViewAllScreen), findsOneWidget);
      expect(offsets, isEmpty);
      await scrollToBottom(tester);
      await tester.pumpAndSettle();
      expect(offsets, [10]);
      expect(find.text('Next anime'), findsWidgets);
    });
  }

  testWidgets('an exhausted seeded page never requests another source page', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ViewAllScreen(
          title: 'الأفضل',
          initialMediaList: [_item('Final result', 'final')],
          category: ViewAllCategory.providerContent,
          initialOffset: 10,
          initialHasMore: false,
          forcePortrait: true,
          loadPage: (_) async {
            calls++;
            return _page([]);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await scrollToBottom(tester);
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('Final result'), findsWidgets);
  });

  testWidgets(
    'an empty Home rail opens View all at the saved discovery cursor',
    (tester) async {
      final offsets = <int>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: MediaHorizontalList(
                title: 'رائج الآن',
                mediaList: const [],
                category: ViewAllCategory.providerContent,
                forcePortrait: true,
                showWhenEmpty: true,
                initialViewAllOffset: 30,
                loadViewAllPage: (offset) async {
                  offsets.add(offset);
                  return ProviderMediaPage(
                    items: [_item('Discovered rank', 'rank-31')],
                    nextOffset: 40,
                    hasMore: false,
                  );
                },
              ),
            ),
          ),
          GoRoute(
            path: '/view-all',
            builder: (context, state) =>
                ViewAllRoute($extra: state.extra! as ViewAllRouteExtra)
                    .build(context, state),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      );
      await tester.tap(find.text('عرض الكل'));
      await tester.pumpAndSettle();
      expect(offsets, [30]);
      expect(find.text('Discovered rank'), findsWidgets);
    },
  );

  testWidgets(
    'ten seeded titles load the next real page only near the bottom',
    (tester) async {
      final offsets = <int>[];
      final response = Completer<ProviderMediaPage>();
      await pumpSeeded(tester, (offset) {
        offsets.add(offset);
        return response.future;
      });
      expect(offsets, isEmpty);
      await scrollToBottom(tester);
      await scrollToBottom(tester);
      expect(offsets, [10]);
      response.complete(
        ProviderMediaPage(
          items: [for (var i = 10; i < 20; i++) _item('Anime $i', '$i')],
          nextOffset: 20,
          hasMore: false,
        ),
      );
      await tester.pumpAndSettle();
      await scrollToBottom(tester);
      await tester.pumpAndSettle();
      expect(find.text('Anime 19'), findsWidgets);
      expect(offsets, [10]);
      expect(
        tester
            .widget<GridView>(find.byType(GridView))
            .childrenDelegate
            .estimatedChildCount,
        20,
      );
    },
  );

  testWidgets('sparse and duplicate pages continue at the current bottom', (
    tester,
  ) async {
    final offsets = <int>[];
    await pumpSeeded(tester, (offset) async {
      offsets.add(offset);
      return ProviderMediaPage(
        items: offset == 10
            ? []
            : offset == 20
            ? [
                MultimediaItem(
                  title: 'Duplicate',
                  url: 'https://animewitcher.com/watch/9/?ref=rank',
                  posterUrl: '',
                ),
              ]
            : [_item('Next ranked title', 'next')],
        nextOffset: offset + 10,
        hasMore: offset < 30,
      );
    });
    await scrollToBottom(tester);
    await tester.pumpAndSettle();
    expect(offsets, [10, 20, 30]);
    expect(find.text('Next ranked title'), findsWidgets);
    expect(find.text('Duplicate'), findsNothing);
    expect(
      tester
          .widget<GridView>(find.byType(GridView))
          .childrenDelegate
          .estimatedChildCount,
      11,
    );
  });

  testWidgets(
    'repeated empty pages stop with retry instead of fetching forever',
    (tester) async {
      final offsets = <int>[];
      await pumpSeeded(tester, (offset) async {
        offsets.add(offset);
        return ProviderMediaPage(
          items: [],
          nextOffset: offset + 10,
          hasMore: true,
        );
      });
      await scrollToBottom(tester);
      await tester.pumpAndSettle();
      expect(offsets, [10, 20, 30]);
      expect(find.text('تعذر تحميل المزيد من النتائج.'), findsOneWidget);
      await scrollToBottom(tester);
      await tester.pumpAndSettle();
      expect(offsets, [10, 20, 30]);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();
      expect(offsets, [10, 20, 30, 40, 50, 60]);
    },
  );

  testWidgets('a failed seeded page waits for retry and keeps its offset', (
    tester,
  ) async {
    final offsets = <int>[];
    await pumpSeeded(tester, (offset) async {
      offsets.add(offset);
      if (offsets.length == 1) throw StateError('offline');
      return ProviderMediaPage(
        items: [_item('Recovered next title', 'next')],
        nextOffset: 20,
        hasMore: false,
      );
    });
    await scrollToBottom(tester);
    await tester.pumpAndSettle();
    expect(find.text('تعذر تحميل المزيد من النتائج.'), findsOneWidget);
    await scrollToBottom(tester);
    await tester.pumpAndSettle();
    expect(offsets, [10]);
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(offsets, [10, 10]);
    expect(find.text('Recovered next title'), findsWidgets);
    expect(find.byType(MultimediaCard), findsWidgets);
  });

  testWidgets('a loader that never finishes becomes retryable', (tester) async {
    await pumpSeeded(tester, (_) => Completer<ProviderMediaPage>().future);
    await scrollToBottom(tester);
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(find.text('تعذر تحميل المزيد من النتائج.'), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
  });

  testWidgets('a late timed-out page cannot append after a successful retry', (
    tester,
  ) async {
    final late = Completer<ProviderMediaPage>();
    var calls = 0;
    await pumpSeeded(tester, (offset) {
      calls++;
      if (calls == 1) return late.future;
      return Future.value(
        ProviderMediaPage(
          items: [_item('Retry result', 'retry')],
          nextOffset: 20,
          hasMore: false,
        ),
      );
    });
    await scrollToBottom(tester);
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    late.complete(
      ProviderMediaPage(
        items: [_item('Stale late result', 'late')],
        nextOffset: 20,
        hasMore: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Retry result'), findsWidgets);
    expect(find.text('Stale late result'), findsNothing);
    expect(
      tester
          .widget<GridView>(find.byType(GridView))
          .childrenDelegate
          .estimatedChildCount,
      11,
    );
  });

  testWidgets(
    'a non-advancing cursor cannot create an automatic request loop',
    (tester) async {
      final offsets = <int>[];
      await pumpSeeded(tester, (offset) async {
        offsets.add(offset);
        return ProviderMediaPage(
          items: [_item('Existing', '0')],
          nextOffset: offset,
          hasMore: true,
        );
      });
      await scrollToBottom(tester);
      await tester.pumpAndSettle();
      expect(offsets, [10]);
      expect(find.text('تعذر تحميل المزيد من النتائج.'), findsOneWidget);
    },
  );

  testWidgets('view all content scrolls under the progressive header', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: ViewAllScreen(
          title: 'All titles',
          initialMediaList: <MultimediaItem>[_item('First', 'first')],
          category: ViewAllCategory.popularTV,
          forcePortrait: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.extendBodyBehindAppBar, isTrue);
    expect(find.byType(AppPageAppBar), findsOneWidget);

    final grid = tester.widget<GridView>(find.byType(GridView).first);
    final padding = grid.padding!.resolve(TextDirection.ltr);
    expect(padding.top, greaterThan(kToolbarHeight));
  });

  testWidgets('a failed first page can be retried', (tester) async {
    var calls = 0;

    Future<ProviderMediaPage> loadPage(int offset) async {
      calls += 1;
      if (calls == 1) throw StateError('offline');
      return _page(<MultimediaItem>[_item('Recovered result', 'recovered')]);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: ViewAllScreen(
          title: 'All titles',
          initialMediaList: const <MultimediaItem>[],
          category: ViewAllCategory.providerContent,
          loadPage: loadPage,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('تعذر تحميل النتائج.'), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsOneWidget);

    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Recovered result'), findsWidgets);
  });

  testWidgets('a failed later page keeps results and can be retried', (
    tester,
  ) async {
    var calls = 0;

    Future<ProviderMediaPage> loadPage(int offset) async {
      calls += 1;
      if (calls == 1) {
        return _page(<MultimediaItem>[
          _item('First result', 'first'),
        ], hasMore: true);
      }
      if (calls == 2) throw StateError('offline');
      return _page(<MultimediaItem>[_item('Second result', 'second')]);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: ViewAllScreen(
          title: 'All titles',
          initialMediaList: const <MultimediaItem>[],
          category: ViewAllCategory.providerContent,
          loadPage: loadPage,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('First result'), findsWidgets);
    expect(find.text('تعذر تحميل المزيد من النتائج.'), findsOneWidget);

    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(calls, 3);
    expect(find.text('First result'), findsWidgets);
    expect(find.text('Second result'), findsWidgets);
  });
}

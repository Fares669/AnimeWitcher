import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  for (final manga in <bool>[false, true]) {
    testWidgets(
      'idle taps schedule navigation and only open one ${manga ? 'manga' : 'anime'}',
      (tester) async {
        Future<void> open(BuildContext context, MultimediaItem item) => manga
            ? MangaDetailsRoute($extra: MangaDetailsRouteExtra(item: item))
                  .push<void>(context)
            : DetailsRoute($extra: DetailsRouteExtra(item: item))
                  .push<void>(context);
        late BuildContext origin;
        final first = MultimediaItem(
          title: 'first',
          url: 'first',
          posterUrl: '',
        );
        final second = MultimediaItem(
          title: 'second',
          url: 'second',
          posterUrl: '',
        );
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) {
                origin = context;
                return const Scaffold(body: Text('catalog'));
              },
            ),
            GoRoute(
              path: manga ? '/details' : '/manga-details',
              builder: (_, _) => const Scaffold(body: Text('other details')),
            ),
            GoRoute(
              path: manga ? '/manga-details' : '/details',
              builder: (context, state) {
                final item = manga
                    ? (state.extra! as MangaDetailsRouteExtra).item
                    : (state.extra! as DetailsRouteExtra).item;
                return Scaffold(
                  body: Column(
                    children: [
                      Text('details ${item.title}'),
                      TextButton(
                        onPressed: () {
                          unawaited(open(context, second));
                        },
                        child: const Text('related'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        );
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);

        // Two different cards (and a repeat) before the next frame is drawn.
        unawaited(open(origin, first));
        unawaited(open(origin, first));
        unawaited(open(origin, second));
        // Mixed anime/manga cards on Home share the same origin lock too.
        unawaited(
          manga
              ? DetailsRoute($extra: DetailsRouteExtra(item: second))
                    .push<void>(origin)
              : MangaDetailsRoute($extra: MangaDetailsRouteExtra(item: second))
                    .push<void>(origin),
        );
        expect(tester.binding.hasScheduledFrame, isTrue);
        await tester.pumpAndSettle();
        expect(find.text('details first'), findsOneWidget);
        expect(find.text('details second'), findsNothing);

        // A related item is allowed from the newly opened details page.
        await tester.tap(find.text('related'));
        await tester.pumpAndSettle();
        expect(find.text('details second'), findsOneWidget);
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text('details first'), findsOneWidget);
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text('catalog'), findsOneWidget);
        expect(router.canPop(), isFalse);

        unawaited(open(origin, second));
        await tester.pumpAndSettle();
        expect(find.text('details second'), findsOneWidget);
        router.pop();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        await open(origin, first); // A stale card callback is harmless.
        router.dispose();
      },
    );
  }

  testWidgets(
    'manga uses a guarded native Navigator fallback and returns results',
    (tester) async {
      late BuildContext origin;
      final observer = _PushObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) {
              origin = context;
              return const Scaffold(body: Text('catalog'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      observer.pushes.clear();
      final item = MultimediaItem(title: 'manga', url: 'manga', posterUrl: '');
      final route = MangaDetailsRoute(
        $extra: MangaDetailsRouteExtra(item: item),
      );
      final result = route.push<String>(origin);
      await route.push<String>(origin);
      expect(observer.pushes, hasLength(1));
      // Pop before building the detail page; this test exercises routing only.
      Navigator.of(origin).pop('closed');
      await expectLater(result, completion('closed'));
      await tester.pumpAndSettle();
      final reopened = route.push<String>(origin);
      expect(observer.pushes, hasLength(2));
      Navigator.of(origin).pop('reopened');
      await expectLater(reopened, completion('reopened'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _PushObserver extends NavigatorObserver {
  final pushes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
  }
}

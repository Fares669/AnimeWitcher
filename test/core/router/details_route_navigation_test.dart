import 'dart:async';

import 'package:animewitcher/core/account/animewitcher_comment_models.dart'
    show animeWitcherNativeProviderId;
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart'
    show animeRiftProviderId;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('cold Rift details links preserve source-qualified identity', () {
    const itemUrl = 'https://anime-rift.com/anime/42';
    final route = DetailsRoute(
      provider: animeRiftProviderId,
      url: itemUrl,
      title: 'Rift title',
    );

    final uri = Uri.parse(route.location);
    expect(uri.path, '/details');
    expect(uri.queryParameters['provider'], animeRiftProviderId);
    expect(uri.queryParameters['url'], itemUrl);
    expect(uri.queryParameters['title'], 'Rift title');

    final item = route.resolvedExtra!.item;
    expect(item.provider, animeRiftProviderId);
    expect(item.url, itemUrl);
    expect(item.title, 'Rift title');
    expect(item.contentType, MultimediaContentType.anime);
  });

  test('cold Rift links canonicalize www identity and ignore poster input', () {
    final route = DetailsRoute(
      provider: animeRiftProviderId,
      url: 'https://www.anime-rift.com/anime/42',
      poster: 'https://attacker.example/pixel.png',
    );

    final item = route.resolvedExtra!.item;
    expect(item.url, 'https://anime-rift.com/anime/42');
    expect(item.posterUrl, isEmpty);
  });

  test('legacy cold details links default to the native provider', () {
    final route = DetailsRoute(url: '/anime/legacy-42', title: 'Legacy');

    expect(route.resolvedExtra!.item.provider, animeWitcherNativeProviderId);
    expect(
      route.resolvedExtra!.item.url,
      'https://animewitcher.com/anime/legacy-42',
    );
  });

  test('native cold links strip query metadata and canonicalize the host', () {
    final route = DetailsRoute(
      provider: animeWitcherNativeProviderId,
      url: 'https://www.animewitcher.com/watch/42?aw_data=%7B%22name%22%3A%22Injected%22%7D&token=secret#private',
    );

    expect(route.resolvedExtra!.item.url, 'https://animewitcher.com/watch/42');
  });

  test('explicit native cold links reject non-native URL identities', () {
    for (final url in <String>[
      'file:///tmp/private-video.mp4',
      'https://foreign.example/watch/42',
      'https://anime-rift.com/anime/42',
    ]) {
      expect(
        DetailsRoute(
          provider: animeWitcherNativeProviderId,
          url: url,
        ).resolvedExtra,
        isNull,
        reason: url,
      );
    }
  });

  test('explicit native relative links become canonical public URLs', () {
    final route = DetailsRoute(
      provider: animeWitcherNativeProviderId,
      url: '/watch/relative-42?aw_data=ignored',
    );

    expect(
      route.resolvedExtra!.item.url,
      'https://animewitcher.com/watch/relative-42',
    );
  });

  test('providerless absolute links cannot cross provider boundaries', () {
    expect(
      DetailsRoute(url: 'https://anime-rift.com/anime/42').resolvedExtra,
      isNull,
    );
    expect(
      DetailsRoute(url: 'https://foreign.example/watch/42').resolvedExtra,
      isNull,
    );
    expect(
      DetailsRoute(url: 'https://animewitcher.com/watch/42').resolvedExtra,
      isNotNull,
    );
  });

  test('cold details links reject internal and unknown providers', () {
    for (final provider in <String>['Local', 'Remote', 'unknown.provider']) {
      final route = DetailsRoute(
        provider: provider,
        url: '/tmp/private-video.mp4',
      );
      expect(route.resolvedExtra, isNull, reason: provider);
    }
  });

  test('cold Rift details links accept only the public HTTPS catalog host', () {
    for (final url in <String>[
      'file:///tmp/private-video.mp4',
      'data:text/plain,secret',
      'http://anime-rift.com/anime/42',
      'https://video.example/anime/42',
      'https://user:secret@anime-rift.com/anime/42',
      'https://anime-rift.com/anime/42?token=secret',
      'https://anime-rift.com/anime/42#signature=private',
      'https://anime-rift.com/video/opaque-stream-token',
      'https://anime-rift.com/anime/42/private/stream',
      'https://anime-rift.com/anime/42%2Fprivate-stream',
      'rift://movie/42',
    ]) {
      expect(
        DetailsRoute(provider: animeRiftProviderId, url: url).resolvedExtra,
        isNull,
        reason: url,
      );
    }
    expect(
      DetailsRoute(
        provider: animeRiftProviderId,
        url: 'https://www.anime-rift.com/anime/42',
      ).resolvedExtra,
      isNotNull,
    );
  });

  test('internal extras may still carry offline provider identities', () {
    final item = MultimediaItem(
      title: 'Offline',
      url: '/tmp/offline.mp4',
      posterUrl: '',
      provider: 'Local',
    );
    final extra = DetailsRouteExtra(item: item);

    expect(DetailsRoute($extra: extra).resolvedExtra, same(extra));
  });

  test('in-app details extras remain authoritative', () {
    final item = MultimediaItem(
      title: 'In-app item',
      url: '/anime/in-app',
      posterUrl: '',
      provider: animeRiftProviderId,
    );
    final extra = DetailsRouteExtra(item: item, autoPlay: true);
    final route = DetailsRoute(
      provider: animeWitcherNativeProviderId,
      url: '/wrong',
      $extra: extra,
    );

    expect(route.resolvedExtra, same(extra));
    expect(route.resolvedExtra!.item, same(item));
    final uri = Uri.parse(route.location);
    expect(uri.queryParameters['provider'], animeWitcherNativeProviderId);
    expect(uri.queryParameters['url'], '/wrong');
  });

  test('in-app extra-only details routes do not serialize item data', () {
    final item = MultimediaItem(
      title: 'Private in-app item',
      url: 'https://catalog.invalid/anime/42?opaque=value',
      posterUrl: 'https://cdn.invalid/poster.jpg',
      provider: animeRiftProviderId,
    );
    final route = DetailsRoute($extra: DetailsRouteExtra(item: item));

    expect(route.resolvedExtra!.item, same(item));
    final uri = Uri.parse(route.location);
    expect(uri.path, '/details');
    expect(uri.queryParameters, isEmpty);
  });

  testWidgets(
    'details route keys screens by provider-qualified item identity',
    (tester) async {
      final first = MultimediaItem(
        title: 'First',
        url: 'https://animewitcher.com/watch/first',
        posterUrl: '',
        provider: animeWitcherNativeProviderId,
      );
      final second = MultimediaItem(
        title: 'Second',
        url: 'https://animewitcher.com/watch/second',
        posterUrl: '',
        provider: animeWitcherNativeProviderId,
      );
      Widget? built;
      final router = GoRouter(
        initialLocation: '/a',
        routes: [
          GoRoute(
            path: '/:id',
            builder: (context, state) {
              final item = state.pathParameters['id'] == 'a' ? first : second;
              built = DetailsRoute($extra: DetailsRouteExtra(item: item))
                  .build(context, state);
              return const SizedBox.shrink();
            },
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      final firstKey = built!.key;
      expect(firstKey, isNotNull);

      router.go('/b');
      await tester.pumpAndSettle();
      expect(built!.key, isNotNull);
      expect(built!.key, isNot(firstKey));
    },
  );

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

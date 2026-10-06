import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('idle taps schedule navigation and only open one anime', (tester) async {
    late BuildContext origin;
    final first = MultimediaItem(title: 'first', url: 'first', posterUrl: '');
    final second = MultimediaItem(title: 'second', url: 'second', posterUrl: '');
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) {
          origin = context;
          return const Scaffold(body: Text('catalog'));
        }),
        GoRoute(path: '/details', builder: (context, state) {
          final extra = state.extra! as DetailsRouteExtra;
          return Scaffold(body: Column(children: [
            Text('details ${extra.item.title}'),
            TextButton(onPressed: () {
              unawaited(DetailsRoute($extra: DetailsRouteExtra(item: second)).push<void>(context));
            }, child: const Text('related')),
          ]));
        }),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);

    // Two different cards (and a repeat) before the next frame is drawn.
    unawaited(DetailsRoute($extra: DetailsRouteExtra(item: first)).push<void>(origin));
    unawaited(DetailsRoute($extra: DetailsRouteExtra(item: first)).push<void>(origin));
    unawaited(DetailsRoute($extra: DetailsRouteExtra(item: second)).push<void>(origin));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('details first'), findsOneWidget);
    expect(find.text('details second'), findsNothing);

    // A related anime is allowed from the newly opened details page.
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

    unawaited(DetailsRoute($extra: DetailsRouteExtra(item: second)).push<void>(origin));
    await tester.pumpAndSettle();
    expect(find.text('details second'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose();
  });
}

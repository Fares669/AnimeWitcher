import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Load = Future<ProviderNewsPage> Function(int offset, int limit);

final _screen = find.byType(NewsListScreen);
const _opener = ValueKey<String>('scope-open-news');
const _size = Size(390, 844);

final class _Call {
  _Call(this.offset, this.limit);

  final int offset;
  final int limit;
  final response = Completer<ProviderNewsPage>();

  void finish(
    String title, {
    int nextOffset = 0,
    bool hasMore = false,
    int count = 1,
  }) {
    response.complete(
      ProviderNewsPage(
        items: [
          for (var i = 0; i < count; i++)
            NewsItem(id: '$title-$i', title: '$title $i', imageUrl: ''),
        ],
        nextOffset: nextOffset,
        hasMore: hasMore,
      ),
    );
  }

  void fail() => response.completeError(StateError('synthetic News failure'));
}

final class _Source {
  final calls = <_Call>[];
  late final _Load load = (offset, limit) {
    final call = _Call(offset, limit);
    calls.add(call);
    return call.response.future;
  };

  List<(int, int)> get keys => [
    for (final call in calls) (call.offset, call.limit),
  ];
}

Future<void> _pump(WidgetTester tester, {int count = 10}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _mount(WidgetTester tester, ValueNotifier<_Load> source) async {
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(source.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: _opener,
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ValueListenableBuilder<_Load>(
                      valueListenable: source,
                      builder: (context, load, _) => NewsListScreen(
                        initialItems: const <NewsItem>[],
                        loadPage: load,
                      ),
                    ),
                  ),
                );
              },
              child: const Text('Open News'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_opener));
  await _pump(tester);
  expect(_screen, findsOneWidget);
}

Future<void> _pull(WidgetTester tester) async {
  await tester.dragFrom(const Offset(195, 170), const Offset(0, 360));
  await _pump(tester);
  expect(find.byType(RefreshProgressIndicator), findsOneWidget);
}

Future<void> _back(WidgetTester tester) async {
  final actual = ModalRoute.of(tester.element(_screen))!;
  await tester.tap(find.byType(AppBackButton).hitTestable());
  await tester.pump();
  expect(actual.isCurrent, isFalse);
  await _pump(tester, count: 14);
  expect(find.byType(NewsListScreen, skipOffstage: false), findsNothing);
}

void main() {
  testWidgets('settled shared error retries fresh, and pending route is local', (
    tester,
  ) async {
    final source = _Source();
    await _mount(tester, ValueNotifier<_Load>(source.load));
    await _open(tester);
    await _pull(tester);
    expect(source.keys, [(0, 20)]);
    source.calls.single.fail();
    await tester.pumpAndSettle();

    await _pull(tester);
    expect(source.keys, [(0, 20), (0, 20)]);
    source.calls.last.finish('retry');
    await tester.pumpAndSettle();
    expect(find.text('retry 0'), findsOneWidget);

    await _pull(tester);
    expect(source.keys, [(0, 20), (0, 20), (0, 20)]);
    final disposed = source.calls.last;
    await _back(tester);
    expect(disposed.response.isCompleted, isFalse);
    await _open(tester);
    expect(source.keys, [(0, 20), (0, 20), (0, 20), (0, 20)]);
    final reopened = source.calls.last;
    disposed.finish('old route');
    await _pump(tester);
    expect(find.text('old route 0'), findsNothing);
    expect(reopened.response.isCompleted, isFalse);
    reopened.finish('new route');
    await tester.pumpAndSettle();
    expect(find.text('new route 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new callback does not join old request, even when switched back', (
    tester,
  ) async {
    final old = _Source();
    final replacement = _Source();
    final selection = ValueNotifier<_Load>(old.load);
    await _mount(tester, selection);
    await _open(tester);
    expect(old.keys, [(0, 20)]);
    selection.value = replacement.load;
    await tester.pump();
    await _pull(tester);
    expect(replacement.keys, [(0, 20)]);
    expect(old.calls.single.response.isCompleted, isFalse);
    replacement.calls.single.finish('replacement');
    // The original source remains in flight; its spinner keeps ticking.
    await _pump(tester);
    expect(find.text('replacement 0'), findsOneWidget);

    selection.value = old.load;
    await tester.pump();
    await _pull(tester);
    expect(old.keys, [(0, 20), (0, 20)]);
    old.calls.first.finish('initial');
    old.calls.last.finish('selected again');
    await tester.pumpAndSettle();
    expect(find.text('selected again 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('positive-offset pagination never joins page-zero refresh', (
    tester,
  ) async {
    final source = _Source();
    await _mount(tester, ValueNotifier<_Load>(source.load));
    await _open(tester);
    source.calls.single.finish('first', count: 8, nextOffset: 20, hasMore: true);
    await tester.pumpAndSettle();

    final scroll = find.byType(Scrollable).first;
    for (var i = 0; i < 15 && source.calls.length < 2; i++) {
      await tester.dragFrom(const Offset(195, 560), const Offset(0, -400));
      await _pump(tester, count: 3);
    }
    expect(source.keys, [(0, 20), (20, 20)]);
    final pagination = source.calls.last;
    for (
      var i = 0;
      i < 15 && tester.state<ScrollableState>(scroll).position.extentBefore > 0;
      i++
    ) {
      await tester.dragFrom(const Offset(195, 360), const Offset(0, 390));
      await _pump(tester, count: 3);
    }
    expect(tester.state<ScrollableState>(scroll).position.extentBefore, 0);
    await _pull(tester);
    expect(source.keys, [(0, 20), (20, 20), (0, 20)]);
    expect(pagination.response.isCompleted, isFalse);
    pagination.finish('append');
    await _pump(tester);
    source.calls.last.finish('refresh');
    await tester.pumpAndSettle();
    expect(find.text('refresh 0'), findsOneWidget);
    expect(find.text('first 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

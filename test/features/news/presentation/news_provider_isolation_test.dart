import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NativeSelection extends AnimeWitcherNativeProvider {
  _NativeSelection([this.loader])
    : super(Dio(), SettingsRepository(StorageService()));
  final Future<ProviderNewsPage> Function()? loader;

  @override
  Future<ProviderNewsPage> getNewsPage({int offset = 0, int limit = 20}) =>
      loader?.call() ?? Future.value(_page());
}

class _Active extends ActiveProvider {
  _Active(this.initial);
  final AnimeWitcherProvider initial;

  @override
  AnimeWitcherProvider? build() => initial;

  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

NewsItem _article() =>
    const NewsItem(id: 'n1', title: 'خبر خاص بمصدر Witcher', imageUrl: '');

ProviderNewsPage _page() =>
    ProviderNewsPage(items: [_article()], nextOffset: 1, hasMore: false);

Future<ProviderContainer> _mount(
  WidgetTester tester, {
  required AnimeWitcherProvider selected,
  required List<NewsItem> initial,
  required Future<ProviderNewsPage> Function(int, int) loadPage,
}) async {
  final container = ProviderContainer(
    overrides: [activeProviderProvider.overrideWith(() => _Active(selected))],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: NewsListScreen(initialItems: initial, loadPage: loadPage),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('Rift empty news never starts the initial fetch', (tester) async {
    var calls = 0;
    await _mount(
      tester,
      selected: AnimeRiftProvider(),
      initial: [],
      loadPage: (_, _) async {
        calls++;
        return _page();
      },
    );
    await tester.pump();
    expect(calls, 0);
    expect(find.text('هذه الميزة غير متاحة للمزود المختار'), findsOneWidget);
  });

  testWidgets('Rift news hides stale Witcher initial items and never loads', (
    tester,
  ) async {
    var calls = 0;
    await _mount(
      tester,
      selected: AnimeRiftProvider(),
      initial: [_article()],
      loadPage: (_, _) async {
        calls++;
        return _page();
      },
    );
    await tester.pump();
    expect(find.text('خبر خاص بمصدر Witcher'), findsNothing);
    expect(find.text('هذه الميزة غير متاحة للمزود المختار'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('Rift round trip discards late page and obsolete loader', (
    tester,
  ) async {
    final pending = Completer<ProviderNewsPage>();
    var calls = 0;
    final container = await _mount(
      tester,
      selected: _NativeSelection(),
      initial: [],
      loadPage: (_, _) {
        calls++;
        return pending.future;
      },
    );
    await tester.pump();
    expect(calls, 1);
    await container
        .read(activeProviderProvider.notifier)
        .set(AnimeRiftProvider());
    await tester.pump();
    expect(find.text('هذه الميزة غير متاحة للمزود المختار'), findsOneWidget);
    await container
        .read(activeProviderProvider.notifier)
        .set(
          _NativeSelection(
            () async => const ProviderNewsPage(
              items: [NewsItem(id: 'new', title: 'خبر جديد', imageUrl: '')],
              nextOffset: 1,
              hasMore: false,
            ),
          ),
        );
    await tester.pump();
    await tester.pump();
    expect(find.text('خبر جديد'), findsOneWidget);
    pending.complete(_page());
    await tester.pump();
    await tester.pump();
    expect(find.text('خبر خاص بمصدر Witcher'), findsNothing);
    expect(calls, 1, reason: 'the old route captured an obsolete loadPage');
  });

  testWidgets('refresh pending during switch cannot restore Witcher rows', (
    tester,
  ) async {
    final pending = Completer<ProviderNewsPage>();
    final container = await _mount(
      tester,
      selected: _NativeSelection(),
      initial: [_article()],
      loadPage: (_, _) => pending.future,
    );
    expect(find.text('خبر خاص بمصدر Witcher'), findsOneWidget);
    // Trigger refresh through the public refresh indicator, not private state.
    final indicator = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    final operation = indicator.onRefresh();
    await tester.pump();
    await container
        .read(activeProviderProvider.notifier)
        .set(AnimeRiftProvider());
    await tester.pump();
    expect(find.text('خبر خاص بمصدر Witcher'), findsNothing);
    pending.complete(_page());
    await operation;
    await tester.pump();
    expect(find.text('خبر خاص بمصدر Witcher'), findsNothing);
    await container
        .read(activeProviderProvider.notifier)
        .set(_NativeSelection());
    await tester.pump();
    expect(find.text('خبر خاص بمصدر Witcher'), findsNothing);
  });
}

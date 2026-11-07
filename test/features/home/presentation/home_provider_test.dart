import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHomeSource extends AnimeWitcherProvider {
  _FakeHomeSource({this.homeDelay = Duration.zero});

  Duration homeDelay;
  int homeCalls = 0;

  @override
  String get packageName => 'fake.home';

  @override
  String get name => 'Fake';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    homeCalls += 1;
    if (homeDelay > Duration.zero) {
      await Future<void>.delayed(homeDelay);
    }
    return <String, List<MultimediaItem>>{
      'الحلقات الجديدة': <MultimediaItem>[
        MultimediaItem(
          title: 'First',
          url: 'https://example.test/first',
          posterUrl: '',
        ),
      ],
    };
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    return const <MultimediaItem>[];
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    return MultimediaItem(title: 'Details', url: url, posterUrl: '');
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    return const <StreamResult>[];
  }
}

class _EmptyManager extends ExtensionManager {
  @override
  List<AnimeWitcherProvider> build() => [];
}

class _DeferredHomeSource extends _FakeHomeSource {
  final home = Completer<Map<String, List<MultimediaItem>>>();

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() => home.future;
}

class _DeferredNewsSource extends _FakeHomeSource {
  final news = Completer<ProviderNewsPage>();

  @override
  String get packageName => 'fake.deferred.news';

  @override
  Future<ProviderNewsPage> getHomeNewsPage({int offset = 0, int limit = 10}) =>
      news.future;
}

class _SwitchableActiveProvider extends ActiveProvider {
  _SwitchableActiveProvider(this.initial);
  final AnimeWitcherProvider initial;

  @override
  AnimeWitcherProvider? build() => initial;

  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('a news response after home disposal is ignored', () async {
    final source = _DeferredNewsSource();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(source),
        extensionManagerProvider.overrideWith(_EmptyManager.new),
      ],
    );
    container.listen<HomeState>(homeDataProvider, (_, _) {});
    await _flush();
    expect(container.read(homeDataProvider), isA<HomeSuccess>());
    container.dispose();

    source.news.complete(
      const ProviderNewsPage(items: [], nextOffset: 0, hasMore: false),
    );
    await _flush();
  });

  for (final unavailable in [false, true]) {
    test(
      'old provider news cannot replace the current home (unavailable=$unavailable)',
      () async {
        final source = _DeferredNewsSource();
        final container = ProviderContainer(
          overrides: [
            activeProviderProvider.overrideWith(
              () => _SwitchableActiveProvider(source),
            ),
            extensionManagerProvider.overrideWith(_EmptyManager.new),
          ],
        );
        addTearDown(container.dispose);
        container.listen<HomeState>(homeDataProvider, (_, _) {});
        await _flush();
        expect(container.read(homeDataProvider), isA<HomeSuccess>());

        await container
            .read(activeProviderProvider.notifier)
            .set(unavailable ? AnimeRiftProvider() : _FakeHomeSource());
        await _flush();
        final current = container.read(homeDataProvider);
        expect(
          current,
          unavailable ? isA<HomeProviderUnavailable>() : isA<HomeSuccess>(),
        );
        source.news.complete(
          const ProviderNewsPage(
            items: [
              NewsItem(id: 'old', title: 'Old provider news', imageUrl: ''),
            ],
            nextOffset: 1,
            hasMore: false,
          ),
        );
        await _flush();
        expect(container.read(homeDataProvider), same(current));
      },
    );
  }

  for (final failure in [false, true]) {
    test(
      'home response after disposal is ignored (failure=$failure)',
      () async {
        final source = _DeferredHomeSource();
        final container = ProviderContainer(
          overrides: [
            activeProviderProvider.overrideWith(
              () => _SwitchableActiveProvider(source),
            ),
            extensionManagerProvider.overrideWith(_EmptyManager.new),
          ],
        );
        container.listen<HomeState>(homeDataProvider, (_, _) {});
        await _flush();
        container.dispose();
        if (failure) {
          source.home.completeError(const AnimeRiftAccessUnavailable());
        } else {
          source.home.complete({
            'home': [
              MultimediaItem(title: 'Late', url: 'test://late', posterUrl: ''),
            ],
          });
        }
        await _flush();
      },
    );
  }

  test(
    'removing the selected provider invalidates an in-flight home response',
    () async {
      final source = _DeferredHomeSource();
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWith(
            () => _SwitchableActiveProvider(source),
          ),
          extensionManagerProvider.overrideWith(_EmptyManager.new),
        ],
      );
      addTearDown(container.dispose);
      container.listen<HomeState>(homeDataProvider, (_, _) {});
      await _flush();
      await container.read(activeProviderProvider.notifier).set(null);
      expect(container.read(homeDataProvider), isA<HomeNoProvider>());

      source.home.complete({
        'old': [
          MultimediaItem(title: 'stale', url: 'test://old', posterUrl: ''),
        ],
      });
      await _flush();
      expect(container.read(homeDataProvider), isA<HomeNoProvider>());
    },
  );

  test(
    'Rift without build configuration displays a recoverable unavailable state',
    () async {
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWithValue(AnimeRiftProvider()),
          extensionManagerProvider.overrideWith(_EmptyManager.new),
        ],
      );
      addTearDown(container.dispose);
      container.listen<HomeState>(homeDataProvider, (_, _) {});
      await _flush();
      final state = container.read(homeDataProvider);
      expect(state, isA<HomeProviderUnavailable>());
      expect(
        (state as HomeProviderUnavailable).message,
        contains('إعدادات المزوّد'),
      );
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps loaded home data when the account revision bumps', () async {
    final source = _FakeHomeSource();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(source),
        extensionManagerProvider.overrideWith(_EmptyManager.new),
      ],
    );
    addTearDown(container.dispose);

    final seen = <Type>[];
    container.listen<HomeState>(homeDataProvider, (previous, next) {
      seen.add(next.runtimeType);
    }, fireImmediately: true);

    await _flush();

    expect(container.read(homeDataProvider), isA<HomeSuccess>());
    expect(source.homeCalls, 1);

    container.read(accountDataRevisionProvider.notifier).bump();
    await _flush();

    expect(container.read(homeDataProvider), isA<HomeSuccess>());
    expect(source.homeCalls, 2);
    expect(seen.where((type) => type == HomeLoading).length, 1);
  });

  test('pull-to-refresh does not flash the home loading shimmer', () async {
    final source = _FakeHomeSource(homeDelay: const Duration(milliseconds: 20));
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(source),
        extensionManagerProvider.overrideWith(_EmptyManager.new),
      ],
    );
    addTearDown(container.dispose);

    container.listen<HomeState>(homeDataProvider, (previous, next) {});
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(container.read(homeDataProvider), isA<HomeSuccess>());

    final seen = <Type>[];
    container.listen<HomeState>(homeDataProvider, (previous, next) {
      seen.add(next.runtimeType);
    });

    await container.read(homeDataProvider.notifier).fetch(keepCurrent: true);
    expect(container.read(homeDataProvider), isA<HomeSuccess>());
    expect(seen, isNot(contains(HomeLoading)));
  });

  test('home data stays cached after the home tab unsubscribes', () async {
    final source = _FakeHomeSource();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(source),
        extensionManagerProvider.overrideWith(_EmptyManager.new),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen<HomeState>(
      homeDataProvider,
      (previous, next) {},
    );
    await _flush();
    expect(container.read(homeDataProvider), isA<HomeSuccess>());
    sub.close();

    expect(container.read(homeDataProvider), isA<HomeSuccess>());
    expect(source.homeCalls, 1);
  });
}

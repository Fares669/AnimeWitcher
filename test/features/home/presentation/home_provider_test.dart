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

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('Rift displays a specific unavailable state when official access is not configured', () async {
    final container = ProviderContainer(overrides: [
      activeProviderProvider.overrideWithValue(AnimeRiftProvider()),
      extensionManagerProvider.overrideWith(_EmptyManager.new),
    ]);
    addTearDown(container.dispose);
    container.listen<HomeState>(homeDataProvider, (_, __) {});
    await _flush();
    final state = container.read(homeDataProvider);
    expect(state, isA<HomeProviderUnavailable>());
    expect((state as HomeProviderUnavailable).message, contains('الاتصال الرسمية'));
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps loaded home data when the account revision bumps', () async {
    final source = _FakeHomeSource();
    final container = ProviderContainer(
      overrides: [activeProviderProvider.overrideWithValue(source), extensionManagerProvider.overrideWith(_EmptyManager.new)],
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
      overrides: [activeProviderProvider.overrideWithValue(source), extensionManagerProvider.overrideWith(_EmptyManager.new)],
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
      overrides: [activeProviderProvider.overrideWithValue(source), extensionManagerProvider.overrideWith(_EmptyManager.new)],
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

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/broadcast_schedule_screen.dart';
import 'package:animewitcher/features/more/presentation/coming_soon_screen.dart';
import 'package:animewitcher/features/more/presentation/global_statistics_screen.dart';
import 'package:animewitcher/features/more/presentation/seasons_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Alternate extends AnimeWitcherProvider {
  @override
  String get packageName => 'alternate';
  @override
  String get name => 'Alternate';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => ['ar'];
  @override
  Set<ProviderType> get supportedTypes => {ProviderType.anime};
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => [];
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => {};
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) async => [];
}

class _EmptyManager extends ExtensionManager {
  @override
  List<AnimeWitcherProvider> build() => [];
}

class _Native extends AnimeWitcherNativeProvider {
  _Native() : super(Dio(), SettingsRepository(StorageService()));
  @override
  Future<ProviderMediaPage> getUpcomingPage({int offset = 0}) async =>
      const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false);
}

class _MutableActive extends ActiveProvider {
  _MutableActive(this.initial);
  final AnimeWitcherProvider initial;
  @override
  AnimeWitcherProvider? build() => initial;
  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

void main() {
  testWidgets('coming soon restores the native page after switching back', (
    tester,
  ) async {
    final alternate = _Alternate();
    final native = _Native();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWith(() => _MutableActive(alternate)),
        extensionManagerProvider.overrideWith(_EmptyManager.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ComingSoonScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('هذه الميزة غير متاحة للمزود المختار'), findsOneWidget);
    await container.read(activeProviderProvider.notifier).set(native);
    await tester.pump();
    await tester.pump();
    expect(find.text('هذه الميزة غير متاحة للمزود المختار'), findsNothing);
    expect(find.text('لا توجد أعمال قادمة حاليًا'), findsOneWidget);
  });

  for (final screen in <Widget>[
    const SeasonsScreen(),
    const ComingSoonScreen(),
    const BroadcastScheduleScreen(),
    const GlobalStatisticsScreen(),
  ]) {
    testWidgets(
      '${screen.runtimeType} does not show another provider catalog',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeProviderProvider.overrideWithValue(_Alternate()),
              extensionManagerProvider.overrideWith(_EmptyManager.new),
            ],
            child: MaterialApp(home: screen),
          ),
        );
        await tester.pump();
        expect(
          find.text('هذه الميزة غير متاحة للمزود المختار'),
          findsOneWidget,
        );
      },
    );
  }
}

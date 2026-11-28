import 'dart:async';
import 'dart:collection';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/providers/update_provider.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/theme/app_theme.dart';
import 'package:animewitcher/core/theme/theme_provider.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/main.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// MyApp is a Flutter MaterialApp.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'core/services/download_v2/download_v2_test_support.dart';
import 'support/memory_storage_service.dart';

class _Storage extends MemoryStorageService {
  @override
  String getLanguage() => 'ar';

  @override
  Future<void> saveThemeMode(String mode) async =>
      settings['theme_mode'] = mode;
}

class _Account extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

class _Home extends HomeData {
  @override
  HomeState build() => const HomeSuccess({});
}

class _Resume extends ContinueWatchingNotifier {
  @override
  List<HistoryItem> build() => const [];
}

class _History extends WatchHistory {
  @override
  List<HistoryItem> build() => const [];
}

class _Gateway extends Fake implements BackgroundDownloaderGateway {
  @override
  Future<void> initialize() async {}

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [];
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 64));
  }
}

void main() {
  testWidgets('production startup reuses both theme inputs without changing '
      'the visible theme or its transitions', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final visibility = VisibilityDetectorController.instance;
    final previousInterval = visibility.updateInterval;
    visibility.updateInterval = Duration.zero;
    addTearDown(() => visibility.updateInterval = previousInterval);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final storage = _Storage();
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: _Gateway(),
      sourceResolver: StaticSourceResolverV2(),
    );
    addTearDown(manager.dispose);
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            handler.reject(DioException(requestOptions: options));
          },
        ),
      );
    addTearDown(() => dio.close(force: true));
    final heldProfile = Completer<DeviceProfile>();
    var profile = heldProfile.future;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountControllerProvider.overrideWith(_Account.new),
          downloadManagerV2Provider.overrideWithValue(manager),
          updateControllerProvider.overrideWithBuild((_, _) => UpdateInitial()),
          deviceProfileProvider.overrideWith((_) => profile),
          dioClientProvider.overrideWithValue(dio),
          activeProviderProvider.overrideWithValue(null),
          extensionManagerProvider.overrideWithBuild((_, _) => []),
          homeDataProvider.overrideWith(_Home.new),
          continueWatchingProvider.overrideWith(_Resume.new),
          watchHistoryProvider.overrideWith(_History.new),
          generalSettingsProvider.overrideWithBuild(
            (_, _) => const GeneralSettings(),
          ),
          homeMalRankingPageProvider.overrideWith(
            (_, _) async => const ProviderMediaPage(
              items: [],
              nextOffset: 0,
              hasMore: false,
            ),
          ),
        ],
        child: const MyApp(),
      ),
    );
    await _frames(tester);

    final setup = find.byType(FirstRunSetupScreen);
    expect(setup, findsOneWidget);
    expect(find.text('المظهر'), findsOneWidget);
    expect(Directionality.of(tester.element(setup)), TextDirection.rtl);
    final setupState = tester.state(setup);
    final homeState = tester.state(
      find.byType(HomeScreen, skipOffstage: false),
    );
    final container = ProviderScope.containerOf(tester.element(setup));
    final scopeTheme = find.byType(MaterialApp);
    final graphIdentities = HashSet<ThemeData>.identity();
    ThemeData visible() => Theme.of(tester.element(setup));

    MaterialApp checkShell(AppThemeStyle style) {
      final shell = tester.widget<MaterialApp>(scopeTheme);
      final light = shell.theme!;
      final dark = shell.darkTheme!;
      final referenceLight = AppTheme.createLightTheme(null);
      final referenceDark = AppTheme.darkThemeFor(style, null);
      expect(shell.themeMode, style.themeMode);
      expect(shell.locale, const Locale('ar'));
      expect(light.platform, referenceLight.platform);
      expect(dark.platform, referenceDark.platform);
      expect(light.colorScheme, referenceLight.colorScheme);
      expect(dark.colorScheme, referenceDark.colorScheme);
      expect(light.textTheme, referenceLight.textTheme);
      expect(dark.textTheme, referenceDark.textTheme);
      expect(light.appBarTheme, referenceLight.appBarTheme);
      expect(dark.appBarTheme, referenceDark.appBarTheme);
      expect(
        tester.widget<WidgetsApp>(find.byType(WidgetsApp)).color,
        AppTheme.animeWitcherAccent,
      );
      graphIdentities
        ..add(light)
        ..add(dark);
      return shell;
    }

    final initial = checkShell(AppThemeStyle.dark);
    expect(visible().colorScheme, initial.darkTheme!.colorScheme);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focus = FocusManager.instance.primaryFocus;
    expect(focus, isNotNull);
    expect(focus!.context!.mounted, isTrue);

    heldProfile.complete(const DeviceProfile(isTv: true));
    await _frames(tester);
    expect(MediaQuery.devicePixelRatioOf(tester.element(setup)), 1);
    expect(tester.state(setup), same(setupState));
    expect(FocusManager.instance.primaryFocus, same(focus));
    final tv = checkShell(AppThemeStyle.dark);
    expect(tv, isNot(same(initial)));
    expect(tv.theme, same(initial.theme));
    expect(tv.darkTheme, same(initial.darkTheme));

    Future<void> setTv(bool enabled) async {
      profile = Future.value(DeviceProfile(isTv: enabled));
      container.invalidate(deviceProfileProvider);
      await _frames(tester);
      expect(
        MediaQuery.devicePixelRatioOf(tester.element(setup)),
        enabled ? 1 : 2,
      );
    }

    await setTv(false);
    final phone = checkShell(AppThemeStyle.dark);
    expect(phone, isNot(same(tv)));
    expect(phone.theme, same(tv.theme));
    expect(phone.darkTheme, same(tv.darkTheme));
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);
    await _frames(tester);
    expect(visible().colorScheme, initial.darkTheme!.colorScheme);

    await tester.ensureVisible(find.text('فاتح'));
    await tester.tap(find.text('فاتح'));
    await tester.pump();
    final light = checkShell(AppThemeStyle.light);
    expect(light.theme, same(initial.theme));
    expect(
      visible().colorScheme.surface,
      initial.darkTheme!.colorScheme.surface,
    );
    await tester.pump(const Duration(milliseconds: 100));
    final midpoint = visible().colorScheme.surface;
    expect(midpoint, isNot(initial.darkTheme!.colorScheme.surface));
    expect(midpoint, isNot(light.theme!.colorScheme.surface));
    await tester.pump(const Duration(milliseconds: 150));
    expect(visible().colorScheme, light.theme!.colorScheme);
    expect(storage.settings[AppThemeStyleNotifier.storageKey], 'light');

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await setTv(true);
    final lightTv = checkShell(AppThemeStyle.light);
    expect(lightTv.theme, same(light.theme));
    expect(lightTv.darkTheme, same(light.darkTheme));
    expect(visible().colorScheme, light.theme!.colorScheme);

    await tester.ensureVisible(find.text('كهرماني'));
    await tester.tap(find.text('كهرماني'));
    await _frames(tester);
    final amber = checkShell(AppThemeStyle.amber);
    expect(amber.theme, same(light.theme));
    expect(visible().colorScheme, amber.darkTheme!.colorScheme);
    expect(visible().brightness, Brightness.dark);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await setTv(false);
    final ios = checkShell(AppThemeStyle.amber);
    expect(ios.theme!.platform, TargetPlatform.iOS);
    expect(ios.darkTheme!.platform, TargetPlatform.iOS);
    expect(ios.theme, isNot(same(amber.theme)));
    expect(ios.darkTheme, isNot(same(amber.darkTheme)));
    expect(visible().colorScheme, amber.darkTheme!.colorScheme);
    expect(tester.state(setup), same(setupState));
    expect(graphIdentities.length, 6);

    for (var step = 0; step < 4; step++) {
      if (find.text('ابدأ المشاهدة').evaluate().isNotEmpty) break;
      await tester.ensureVisible(find.text('التالي'));
      await tester.tap(find.text('التالي'));
      await _frames(tester);
    }
    await tester.ensureVisible(find.text('ابدأ المشاهدة'));
    await tester.tap(find.text('ابدأ المشاهدة'));
    await _frames(tester);
    expect(setup, findsNothing);
    expect(tester.state(find.byType(HomeScreen)), same(homeState));
    expect(storage.settings[FirstRunSetup.storageKey], 'done');
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/providers/update_provider.dart';
import 'package:animewitcher/core/services/app_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/features/search/presentation/search_screen.dart';
import 'package:animewitcher/main.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// MyApp exposes Flutter MaterialApp.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'core/services/download_v2/download_v2_test_support.dart';
import 'support/memory_storage_service.dart';

const _stock = bool.fromEnvironment('C27_STARTUP_STOCK');
const _card = 'عمل محلي للبداية';

final class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  final gate = Completer<void>();
  int documentLookups = 0;
  @override
  Future<String?> getApplicationDocumentsPath() async {
    documentLookups++;
    await gate.future;
    return path;
  }

  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Storage extends MemoryStorageService {
  final ready = Completer<void>();
  int starts = 0;
  @override
  Future<void> init() {
    starts++;
    return ready.future;
  }

  @override
  String getLanguage() => 'ar';
}

class _GuestSecureStorage extends SecureTokenStorage {
  _GuestSecureStorage(super.storage);
  int reads = 0;
  @override
  Future<String?> read(String key) async {
    reads++;
    return null;
  }
}

class _Catalog extends AnimeWitcherProvider {
  @override
  String get packageName => 'fixture.cold-start';
  @override
  String get name => 'Local catalog';
  @override
  String get mainUrl => 'https://fixture.invalid';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => _homeRows;
  @override
  Future<MultimediaItem> getDetails(String url) async =>
      _homeRows.values.first.first;
  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const [];
}

final _homeRows = <String, List<MultimediaItem>>{
  'الأعمال المحلية': [
    MultimediaItem(
      url: 'https://fixture.invalid/local-anime',
      title: _card,
      posterUrl: '',
      provider: 'fixture.cold-start',
      contentType: MultimediaContentType.anime,
    ),
  ],
};

class _Home extends HomeData {
  @override
  HomeState build() => HomeSuccess(_homeRows);
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
  int starts = 0;
  @override
  Future<void> initialize() async {
    starts++;
  }

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [];
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<String> _snapshot(WidgetTester tester, Key key) async {
  final box = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  return (await tester.runAsync(() async {
    final image = await box.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return sha256.convert(bytes!.buffer.asUint8List()).toString();
    } finally {
      image.dispose();
    }
  }))!;
}

Future<void> _flushLogs(WidgetTester tester) async {
  var drained = false;
  unawaited(appDiagnostics.flush().then((_) => drained = true));
  // I/O completes off-isolate, but queued writes are scheduled in the
  // widget test zone. Give both schedulers a turn without changing UI time.
  for (var step = 0; step < 180 && !drained; step++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
  }
  await tester.pump();
  expect(drained, isTrue, reason: 'the real JSONL queue settled');
}

void main() {
  testWidgets('Arabic root and first route preserve offline diagnostics', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final visibility = VisibilityDetectorController.instance;
    final oldInterval = visibility.updateInterval;
    visibility.updateInterval = Duration.zero;
    addTearDown(() => visibility.updateInterval = oldInterval);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('c27-startup-route-'),
    ))!;
    final oldPaths = PathProviderPlatform.instance;
    final paths = _Paths(dir.path);
    PathProviderPlatform.instance = paths;
    addTearDown(() async {
      if (!paths.gate.isCompleted) paths.gate.complete();
      PathProviderPlatform.instance = oldPaths;
      await dir.delete(recursive: true);
    });
    PackageInfo.setMockInitialValues(
      appName: 'Offline fixture',
      packageName: 'fixture.local',
      version: '1.2.3',
      buildNumber: '4',
      buildSignature: '',
    );

    final storage = _Storage()
      ..settings[FirstRunSetup.storageKey] = 'done'
      ..settings['theme_mode'] = 'dark';
    final gateway = _Gateway();
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: gateway,
      sourceResolver: StaticSourceResolverV2(),
    );
    addTearDown(manager.dispose);
    final requests = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options.uri.host);
            handler.reject(DioException(requestOptions: options));
          },
        ),
      );
    addTearDown(() => dio.close(force: true));
    final source = _Catalog();
    final guestSecure = _GuestSecureStorage(storage);
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: guestSecure,
    );
    var artworkProbes = 0;
    var appMounts = 0;
    const frame = ValueKey('c27-startup-frame');

    await tester.pumpWidget(
      RepaintBoundary(
        key: frame,
        child: ProviderScope(
          // The real routes request dependent providers, so supply the same
          // storage and offline service fakes from their common scope.
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            animeWitcherAccountServiceProvider.overrideWithValue(account),
            downloadManagerV2Provider.overrideWithValue(manager),
            updateControllerProvider.overrideWithBuild(
              (_, _) => UpdateInitial(),
            ),
            deviceProfileProvider.overrideWith(
              (_) async => const DeviceProfile(),
            ),
            dioClientProvider.overrideWithValue(dio),
            activeProviderProvider.overrideWithValue(source),
            extensionManagerProvider.overrideWithBuild((_, _) => [source]),
            homeDataProvider.overrideWith(_Home.new),
            continueWatchingProvider.overrideWith(_Resume.new),
            watchHistoryProvider.overrideWith(_History.new),
          ],
          child: AppRoot.test(
            storage,
            ({required timeout}) async {
              artworkProbes++;
              return false;
            },
            Builder(
              builder: (_) {
                appMounts++;
                return const MyApp();
              },
            ),
          ),
        ),
      ),
    );
    expect(storage.starts, 1);
    expect(find.byType(MyApp), findsNothing);
    expect(artworkProbes, 0);
    storage.ready.complete();
    await _frames(tester);
    final home = find.byType(HomeScreen);
    expect(home.hitTestable(), findsOneWidget);
    expect(find.text(_card).hitTestable(), findsWidgets);
    expect(Directionality.of(tester.element(home)), TextDirection.rtl);
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.locale, const Locale('ar'));
    expect(material.themeMode, ThemeMode.dark);
    expect(artworkProbes, 1);
    expect(appMounts, 1);
    expect(gateway.starts, 1);
    final scope = ProviderScope.containerOf(tester.element(home));
    for (
      var attempt = 0;
      attempt < 10 &&
          scope.read(animeWitcherAccountControllerProvider).isLoading;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      scope.read(animeWitcherAccountControllerProvider).requireValue.isSignedIn,
      isFalse,
    );
    expect(scope.read(accountDataRevisionProvider), 0);
    expect(guestSecure.reads, greaterThan(0));

    final homeFrame = await _snapshot(tester, frame);
    await tester.tap(find.byIcon(Icons.search_outlined).hitTestable().last);
    await _frames(tester);
    // The dock highlight slides for 260 ms. Compare settled screens, not
    // whichever intermediate animation timestamp the host happened to draw.
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(SearchScreen).hitTestable(), findsOneWidget);
    final searchFrame = await _snapshot(tester, frame);
    // UI mounted and changed routes before allowing either arm to resolve
    // the Documents path, so logger scheduling cannot determine readiness.
    expect(paths.documentLookups, 1);
    paths.gate.complete();
    await _flushLogs(tester);
    expect(requests, isEmpty);

    final file = File('${dir.path}/log/app.jsonl');
    final lines = (await tester.runAsync(file.readAsLines))!;
    final rows = <Map<String, Object?>>[
      for (final line in lines)
        (jsonDecode(line) as Map).cast<String, Object?>(),
    ];
    final events = rows.map((row) => row['event']).toList();
    expect(
      events,
      containsAllInOrder([
        'app.storage.init.start',
        'app.storage.init.complete',
        'app.navigation.push',
      ]),
    );
    for (final row in rows) {
      expect(row['buildFingerprint'], '1.2.3+4');
      expect(row.values, isNot(contains('https://fixture.invalid')));
    }
    if (_stock || !Platform.isLinux) {
      expect(paths.documentLookups, rows.length);
    } else {
      expect(paths.documentLookups, 1);
    }
    debugPrint(
      'C27_STARTUP ${rows.length} lookups=${paths.documentLookups} '
      'events=$events rgba=[$homeFrame,$searchFrame]',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}

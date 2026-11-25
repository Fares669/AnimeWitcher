import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/providers/update_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/theme/app_theme.dart';
import 'package:animewitcher/core/theme/theme_provider.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/main.dart';
// MyApp exposes Flutter Material widgets, not material_ui widgets.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'core/services/download_v2/download_v2_test_support.dart';
import 'support/memory_storage_service.dart';

class _Storage extends MemoryStorageService {
  @override
  String getLanguage() => 'ar';
}

class _Session extends AnimeWitcherAccountController {
  bool _restored = false;

  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    _restored = true;
    return const AnimeWitcherAccountSnapshot();
  }

  void finishSync() {
    state = AsyncData(AnimeWitcherAccountSnapshot(lastSyncAt: DateTime(2026)));
  }
}

class _Gateway extends Fake implements BackgroundDownloaderGateway {
  @override
  Future<void> initialize() async {}

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [];
}

void main() {
  testWidgets('restoring and syncing a session leaves the app shell in place', (
    tester,
  ) async {
    final session = _Session();
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: _Gateway(),
      sourceResolver: StaticSourceResolverV2(),
    );
    addTearDown(manager.dispose);
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const Text('home'))],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(
            _Storage()..settings[AppThemeStyleNotifier.storageKey] = 'dark',
          ),
          appRouterProvider.overrideWith((_) => router),
          animeWitcherAccountControllerProvider.overrideWith(() => session),
          downloadManagerV2Provider.overrideWithValue(manager),
          updateControllerProvider.overrideWithBuild((_, _) => UpdateInitial()),
          generalSettingsProvider.overrideWithBuild(
            (_, _) => const GeneralSettings(),
          ),
        ],
        child: const MyApp(),
      ),
    );
    await tester.pumpAndSettle();
    final shell = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(find.text('home'), findsOneWidget);
    expect(session._restored, isTrue);
    expect(shell.locale, const Locale('ar'));
    expect(shell.darkTheme!.colorScheme.primary, AppTheme.animeWitcherAccent);
    session.finishSync();
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(shell));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('startup errors still expose the Arabic recovery screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      LaunchErrorApp(error: 'storage unavailable', storageService: _Storage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('storage unavailable'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
      const Locale('ar'),
    );
  });
}

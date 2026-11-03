import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/settings/presentation/widgets/anime_provider_picker.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestProvider extends AnimeWitcherProvider {
  _TestProvider(this.packageName, this.name, this.supportedTypes);

  @override
  final String packageName;
  @override
  final String name;
  @override
  final Set<ProviderType> supportedTypes;
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
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

class _TestManager extends ExtensionManager {
  _TestManager(this.providers);

  final List<AnimeWitcherProvider> providers;

  @override
  List<AnimeWitcherProvider> build() => providers;
}

class _SavedSettings extends SettingsRepository {
  _SavedSettings(this.savedId) : super(StorageService());

  String? savedId;

  @override
  String? getActiveProviderId() => savedId;

  @override
  Future<void> setActiveProviderId(String? id) async => savedId = id;
}

class _DelayedSettings extends _SavedSettings {
  _DelayedSettings(super.savedId);
  final calls = <String?>[];
  final releases = <Completer<void>>[];
  @override
  Future<void> setActiveProviderId(String? id) async {
    calls.add(id);
    final gate = Completer<void>();
    releases.add(gate);
    await gate.future;
    savedId = id;
  }
}

class _RiftAccountFixture extends AnimeRiftApiClient {
  _RiftAccountFixture({this.linked = false});

  bool linked;
  final codes = <String>[];
  var signOuts = 0;

  @override
  bool get isAccountLinked => linked;

  @override
  Future<bool> restoreAccountSession() async => linked;

  @override
  Future<void> signInWithCode(String code) async {
    codes.add(code);
    linked = true;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    linked = false;
  }
}

Widget _app(List<AnimeWitcherProvider> registered, _SavedSettings settings) {
  return ProviderScope(
    overrides: [
      extensionManagerProvider.overrideWith(() => _TestManager(registered)),
      settingsRepositoryProvider.overrideWithValue(settings),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ListView(
          children: const [
            AnimeProviderSettingsTile(),
            AnimeRiftAccountSettingsTile(),
          ],
        ),
      ),
    ),
  );
}

void main() {
  final native = _TestProvider('native', 'AnimeWitcher', {ProviderType.anime});
  final other = _TestProvider('other', 'Alternative Anime', {
    ProviderType.anime,
  });
  final manga = _TestProvider('manga', 'Manga Only', {ProviderType.manga});

  test(
    'default selection cannot overwrite an immediate user selection',
    () async {
      final settings = _DelayedSettings('stale-id');
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _TestManager([native, other]),
          ),
          settingsRepositoryProvider.overrideWithValue(settings),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(activeProviderProvider), same(native));
      final selected = container
          .read(activeProviderProvider.notifier)
          .set(other);
      await Future<void>.delayed(Duration.zero);
      expect(settings.calls, ['other']);
      settings.releases.single.complete();
      await selected;
      expect(settings.savedId, 'other');
    },
  );

  test('rapid changes persist in order even with slow storage', () async {
    final settings = _DelayedSettings('native');
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _TestManager([native, other]),
        ),
        settingsRepositoryProvider.overrideWithValue(settings),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(activeProviderProvider), same(native));
    final first = container.read(activeProviderProvider.notifier).set(other);
    final second = container.read(activeProviderProvider.notifier).set(native);
    await Future<void>.delayed(Duration.zero);
    expect(settings.calls, ['other']);
    settings.releases.first.complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(settings.calls, ['other', 'native']);
    settings.releases.last.complete();
    await second;
    expect(settings.savedId, 'native');
  });

  testWidgets('restores the saved anime provider, switches and persists it', (
    tester,
  ) async {
    final settings = _SavedSettings('other');
    final providers = [native, other, manga];
    await tester.pumpWidget(_app(providers, settings));
    await tester.pumpAndSettle();

    expect(find.text('Alternative Anime'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('settings-anime-provider')),
        matching: find.byType(ListTile),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.byKey(const ValueKey('anime-provider-option-native')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('anime-provider-option-other')),
      findsOneWidget,
    );
    expect(find.text('Manga Only'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('anime-provider-option-native')),
    );
    await tester.pumpAndSettle();
    expect(settings.savedId, 'native');
    expect(find.text('AnimeWitcher'), findsOneWidget);

    // A new provider scope should recover the last selected ID from storage.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_app(providers, settings));
    await tester.pumpAndSettle();
    expect(find.text('AnimeWitcher'), findsOneWidget);
    expect(settings.savedId, 'native');
  });

  testWidgets('Anime Rift appears as an anime option and persists selection', (
    tester,
  ) async {
    final settings = _SavedSettings(null);
    final providers = [native, AnimeRiftProvider(), manga];
    await tester.pumpWidget(_app(providers, settings));
    await tester.pumpAndSettle();

    expect(find.text('AnimeWitcher'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('settings-anime-provider')),
        matching: find.byType(ListTile),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('anime-provider-option-$animeRiftProviderId')),
      findsOneWidget,
    );
    expect(find.text('Manga Only'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('anime-provider-option-$animeRiftProviderId')),
    );
    await tester.pumpAndSettle();
    expect(settings.savedId, animeRiftProviderId);
    expect(find.text('Anime Rift'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_app(providers, settings));
    await tester.pumpAndSettle();
    expect(find.text('Anime Rift'), findsOneWidget);
  });

  testWidgets(
    'Rift account links and signs out without changing the selected provider',
    (tester) async {
      final settings = _SavedSettings('native');
      final account = _RiftAccountFixture();
      final rift = AnimeRiftProvider(client: account);
      await tester.pumpWidget(_app([native, rift, manga], settings));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-animerift-account')),
        findsOneWidget,
      );
      expect(find.textContaining('غير مربوط'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('settings-animerift-account')),
      );
      await tester.pumpAndSettle();
      expect(find.text('ربط حساب Anime Rift'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('animerift-code-field')),
        '  owner-issued-code  ',
      );
      await tester.tap(find.byKey(const ValueKey('animerift-account-submit')));
      await tester.pumpAndSettle();

      expect(account.codes, ['owner-issued-code']);
      expect(settings.savedId, 'native');
      expect(find.textContaining('مربوط'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('settings-animerift-account')),
      );
      await tester.pumpAndSettle();
      expect(find.text('إلغاء ربط حساب Anime Rift؟'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('animerift-account-signout-confirm')),
      );
      await tester.pumpAndSettle();

      expect(account.signOuts, 1);
      expect(settings.savedId, 'native');
      expect(find.textContaining('غير مربوط'), findsOneWidget);
    },
  );

  testWidgets('shows only registered anime providers, without placeholders', (
    tester,
  ) async {
    await tester.pumpWidget(_app([native, manga], _SavedSettings(null)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('settings-anime-provider')),
        matching: find.byType(ListTile),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    expect(
      find.byKey(const ValueKey('anime-provider-option-native')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('anime-provider-option-manga')),
      findsNothing,
    );
    expect(find.byType(ListTile), findsWidgets);
  });

  testWidgets('disables selection when no anime provider is registered', (
    tester,
  ) async {
    await tester.pumpWidget(_app([manga], _SavedSettings(null)));
    await tester.pumpAndSettle();
    expect(find.text('لا يوجد مزود أنمي متاح'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-animerift-account')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('settings-anime-provider')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}

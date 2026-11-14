import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _SignedInWitcher extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot(
        profile: AnimeWitcherProfile(
          documentId: 'witcher',
          uid: 'witcher-uid',
          signInMethod: AnimeWitcherSignInMethod.email,
          userName: 'Witcher User',
          email: 'witcher@example.test',
        ),
      );
}

class _RiftClient extends AnimeRiftApiClient {
  bool linked = true;
  int signOuts = 0;

  @override
  bool get isAccountLinked => linked;
  @override
  AnimeRiftAccountIdentity? get accountIdentity => linked
      ? const AnimeRiftAccountIdentity(
          id: 'rift-uid',
          displayName: 'Rift Viewer',
        )
      : null;
  @override
  Future<bool> restoreAccountSession() async => linked;

  @override
  Future<void> signOut() async {
    linked = false;
    signOuts++;
  }
}

class _SelectedProvider extends ActiveProvider {
  _SelectedProvider(this.selected);
  final AnimeRiftProvider selected;
  @override
  AnimeRiftProvider build() => selected;
}

class _ProviderRegistry extends ExtensionManager {
  _ProviderRegistry(this.selected);
  final AnimeRiftProvider selected;
  @override
  List<AnimeRiftProvider> build() => [selected];
}

void main() {
  testWidgets('More displays Rift identity and opens its own account', (
    tester,
  ) async {
    final riftClient = _RiftClient();
    final rift = AnimeRiftProvider(client: riftClient);
    tester.view.physicalSize = const Size(390, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(MemoryStorageService()),
          animeWitcherAccountControllerProvider.overrideWith(
            _SignedInWitcher.new,
          ),
          extensionManagerProvider.overrideWith(() => _ProviderRegistry(rift)),
          activeProviderProvider.overrideWith(() => _SelectedProvider(rift)),
        ],
        child: const MaterialApp(
          locale: Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MoreScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Rift Viewer'), findsOneWidget);
    expect(find.text('Witcher User'), findsNothing);
    expect(find.text('witcher@example.test'), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MoreScreen)),
    );
    expect(
      (await container.read(animeWitcherAccountControllerProvider.future))
          .profile
          ?.userName,
      'Witcher User',
    );

    await tester.tap(find.text('Rift Viewer'));
    await tester.pumpAndSettle();
    expect(find.text('حساب Anime Rift'), findsOneWidget);
    expect(find.text('البريد الإلكتروني'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-animerift-account')));
    await tester.pumpAndSettle();
    expect(find.text('إلغاء ربط حساب Anime Rift؟'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('animerift-account-signout-confirm')),
    );
    await tester.pumpAndSettle();

    expect(riftClient.signOuts, 1);
    expect(
      container
          .read(animeWitcherAccountControllerProvider)
          .asData
          ?.value
          .profile
          ?.userName,
      'Witcher User',
    );
  });
}

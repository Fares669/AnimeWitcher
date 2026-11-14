import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/shared/widgets/account_avatar_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Account extends AnimeWitcherAccountController {
  _Account(this.profile);

  final AnimeWitcherProfile? profile;

  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      AnimeWitcherAccountSnapshot(profile: profile);
}

class _RiftClient extends AnimeRiftApiClient {
  @override
  bool get isAccountLinked => true;

  @override
  AnimeRiftAccountIdentity? get accountIdentity =>
      const AnimeRiftAccountIdentity(id: 'rift-1', displayName: 'Rift Viewer');

  @override
  Future<bool> restoreAccountSession() async => true;
}

class _SelectedProvider extends ActiveProvider {
  _SelectedProvider(this.provider);
  final AnimeWitcherProvider? provider;

  @override
  AnimeWitcherProvider? build() => provider;
}

Future<void> _pump(
  WidgetTester tester, {
  AnimeWitcherProfile? profile,
  VoidCallback? onTap,
  bool rift = false,
}) async {
  final riftProvider = AnimeRiftProvider(client: _RiftClient());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        animeWitcherAccountControllerProvider.overrideWith(
          () => _Account(profile),
        ),
        activeProviderProvider.overrideWith(
          () => _SelectedProvider(rift ? riftProvider : null),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: AccountAvatarButton(onTap: onTap ?? () {})),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('signed out it shows a person and offers to sign in', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.byIcon(Icons.person_outline_rounded), findsOneWidget);
    expect(find.byTooltip('تسجيل الدخول'), findsOneWidget);
  });

  testWidgets('signed in without a photo it shows the first letter', (
    tester,
  ) async {
    await _pump(
      tester,
      profile: const AnimeWitcherProfile(
        documentId: 'd1',
        uid: 'u1',
        signInMethod: AnimeWitcherSignInMethod.email,
        userName: 'witcher',
      ),
    );

    expect(find.text('W'), findsOneWidget);
    expect(find.byTooltip('witcher'), findsOneWidget);
  });

  testWidgets('a tap opens whatever the caller gave it', (tester) async {
    var taps = 0;
    await _pump(tester, onTap: () => taps++);

    await tester.tap(
      find.byKey(const ValueKey<String>('account-avatar-button')),
    );
    expect(taps, 1);
  });

  testWidgets('Rift selection never exposes the Witcher avatar or identity', (
    tester,
  ) async {
    await _pump(
      tester,
      rift: true,
      profile: const AnimeWitcherProfile(
        documentId: 'witcher-profile',
        uid: 'witcher-user',
        signInMethod: AnimeWitcherSignInMethod.email,
        userName: 'Witcher User',
      ),
    );

    expect(find.text('W'), findsNothing);
    expect(find.byTooltip('Witcher User'), findsNothing);
    expect(find.text('R'), findsOneWidget);
    expect(find.byTooltip('Rift Viewer'), findsOneWidget);
  });
}

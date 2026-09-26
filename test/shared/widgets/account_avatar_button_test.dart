import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
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

Future<void> _pump(
  WidgetTester tester, {
  AnimeWitcherProfile? profile,
  VoidCallback? onTap,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        animeWitcherAccountControllerProvider.overrideWith(
          () => _Account(profile),
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
    expect(find.byTooltip('Sign in'), findsOneWidget);
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
}

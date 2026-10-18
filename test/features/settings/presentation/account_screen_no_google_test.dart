import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/features/settings/presentation/account_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _SignedOutAccount extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return const AnimeWitcherAccountSnapshot();
  }
}

void main() {
  testWidgets('signed-out account screen offers email auth without Google', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeWitcherAccountControllerProvider.overrideWith(
            _SignedOutAccount.new,
          ),
        ],
        child: const MaterialApp(
          locale: Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AnimeWitcherAccountScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('الحساب'), findsOneWidget);
    expect(find.text('حساب AnimeWitcher'), findsNothing);
    expect(find.text('البريد الإلكتروني'), findsOneWidget);
    expect(find.text('كلمة المرور'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'تسجيل الدخول'), findsOneWidget);
    expect(find.textContaining('Google'), findsNothing);
  });
}

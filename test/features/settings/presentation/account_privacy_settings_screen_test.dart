import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/features/settings/presentation/account_privacy_settings_screen.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('account privacy header keeps title right and back left', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        home: Builder(
          builder: (context) => Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const AnimeWitcherPrivacySettingsScreen(
                initialSettings: AnimeWitcherPrivacySettings(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = find.text('الخصوصية والمحتوى');
    final back = find.byType(AppBackButton);
    expect(title, findsOneWidget);
    expect(back, findsOneWidget);
    expect(tester.getCenter(title).dx, greaterThan(230));
    expect(tester.getCenter(back).dx, lessThan(80));
  });

  testWidgets('privacy toggles use themed Material switches on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    const accent = Color(0xFF8A5CFF);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        theme: ThemeData(
          colorScheme: const ColorScheme.dark(primary: accent),
          switchTheme: SwitchThemeData(
            trackColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? accent
                  : const Color(0xFF333333),
            ),
          ),
        ),
        home: const AnimeWitcherPrivacySettingsScreen(
          initialSettings: AnimeWitcherPrivacySettings(
            showFavoritesToUsers: true,
            showCommentsToUsers: true,
            showReviewsToUsers: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsNWidgets(4));
    expect(find.byType(CupertinoSwitch), findsNothing);
  });
}

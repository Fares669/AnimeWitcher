import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/features/settings/presentation/account_screen.dart';
import 'package:animewitcher/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:animewitcher/features/comments/presentation/animewitcher_my_comments_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';

class _SignedInAccount extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return const AnimeWitcherAccountSnapshot(
      profile: AnimeWitcherProfile(
        documentId: 'test-profile',
        uid: 'test-user',
        signInMethod: AnimeWitcherSignInMethod.email,
        email: 'a@b.co',
        userName: 'Reader',
        providerIds: ['password'],
      ),
    );
  }
}

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? pushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed = route;
  }
}

void main() {
  for (final width in [320.0, 428.0]) {
    testWidgets(
      'email management card uses a description and navigation chevron at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 926);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(
          () => TestFonts.loadFamily('Readex Pro', [
            'assets/fonts/readex_pro/ReadexPro-Regular.ttf',
            'assets/fonts/readex_pro/ReadexPro-Bold.ttf',
          ]),
        );
        final observer = _RouteObserver();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              animeWitcherAccountControllerProvider.overrideWith(
                _SignedInAccount.new,
              ),
            ],
            child: MaterialApp(
              navigatorObservers: [observer],
              locale: const Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData(fontFamily: 'Readex Pro'),
              home: const AnimeWitcherAccountScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('الحساب'), findsOneWidget);
        expect(find.text('حساب AnimeWitcher'), findsNothing);
        final bell = find.byKey(const ValueKey('account-notifications-button'));
        expect(bell, findsOneWidget);
        expect(tester.getCenter(bell).dx, greaterThan(width / 2));

        final title = find.text('تغيير البريد الإلكتروني');
        final card = find.ancestor(of: title, matching: find.byType(ListTile));
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();

        final tile = tester.widget<ListTile>(card);
        expect(tile.subtitle, isNotNull);
        expect(tile.trailing, isA<Icon>());
        expect((tile.trailing! as Icon).icon, Icons.chevron_left_rounded);

        final description = find.descendant(
          of: card,
          matching: find.text('يجب التحقق من البريد الجديد'),
        );
        expect(description, findsOneWidget);
        expect(
          tester.getRect(description).top,
          greaterThan(tester.getRect(title).top),
        );
        expect(
          tester.getRect(description).right,
          closeTo(tester.getRect(title).right, 0.01),
        );
        expect(
          tester
              .getCenter(
                find.descendant(
                  of: card,
                  matching: find.byIcon(Icons.alternate_email_rounded),
                ),
              )
              .dx,
          greaterThan(tester.getRect(title).right),
        );
        expect(
          tester
              .getCenter(
                find.descendant(
                  of: card,
                  matching: find.byIcon(Icons.chevron_left_rounded),
                ),
              )
              .dx,
          lessThan(tester.getRect(title).left),
        );
        expect(tester.takeException(), isNull);

        final comments = find.widgetWithText(SettingsTile, 'تعليقاتي');
        await tester.ensureVisible(comments);
        await tester.pumpAndSettle();
        expect(
          tester.widget<SettingsTile>(comments).icon,
          Icons.chat_bubble_outline_rounded,
        );
        await tester.tap(comments);
        final route = observer.pushed! as MaterialPageRoute<void>;
        final screen = route.builder(tester.element(comments));
        expect(screen, isA<AnimeWitcherMyCommentsScreen>());
        expect((screen as AnimeWitcherMyCommentsScreen).isReviews, isFalse);
        route.navigator!.removeRoute(route);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}

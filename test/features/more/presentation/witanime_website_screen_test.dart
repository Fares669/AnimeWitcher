import 'package:animewitcher/features/more/presentation/witanime_website_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Witanime account and support open their official browser pages',
    (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WitanimeWebsiteScreen(
            openLink: (uri) async {
              opened.add(uri);
              return uri.path != '/contact';
            },
          ),
        ),
      );
      expect(find.text('حساب Witanime على الموقع'), findsOneWidget);
      for (final title in [
        'تسجيل الدخول',
        'إنشاء حساب',
        'استعادة كلمة المرور',
      ]) {
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
      }
      await tester.drag(find.byType(ListView), const Offset(0, -390));
      await tester.pumpAndSettle();
      await tester.tap(find.text('التواصل'));
      await tester.pumpAndSettle();
      expect(find.text('تعذر فتح موقع Witanime.'), findsOneWidget);
      expect(opened.map((uri) => uri.toString()), [
        'https://witanime.site/login',
        'https://witanime.site/register',
        'https://witanime.site/forgot-password',
        'https://witanime.site/contact',
      ]);
    },
  );
}

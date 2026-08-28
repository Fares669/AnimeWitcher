import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/features/characters/presentation/characters_screen.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
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

class _EmptyExtensions extends ExtensionManager {
  @override
  List<AnimeWitcherProvider> build() => const <AnimeWitcherProvider>[];
}

class _EmptyActive extends ActiveProvider {
  @override
  AnimeWitcherProvider? build() => null;
}

Widget _app(Widget home) {
  return ProviderScope(
    overrides: [
      animeWitcherAccountControllerProvider.overrideWith(
        _SignedOutAccount.new,
      ),
      extensionManagerProvider.overrideWith(_EmptyExtensions.new),
      activeProviderProvider.overrideWith(_EmptyActive.new),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

void main() {
  testWidgets('more screen links to the characters experience', (tester) async {
    await tester.pumpWidget(_app(const MoreScreen()));
    await tester.pumpAndSettle();

    expect(find.text('الشخصيات'), findsOneWidget);
    expect(
      find.text('تصفح الشخصيات وابحث عنها وأدر المفضلة'),
      findsOneWidget,
    );
  });

  testWidgets('characters page shows an on-page search field', (tester) async {
    await tester.pumpWidget(_app(const CharactersScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('الشخصيات'), findsWidgets);
    expect(find.text('من الذي ترغب بالبحث عنه؟'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    expect(find.text('المفضلة'), findsOneWidget);
  });
}

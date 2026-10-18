import 'package:animewitcher/core/providers/locale_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _LanguageStorage extends StorageService {
  _LanguageStorage(this.language);

  String language;

  @override
  String getLanguage() => language;

  @override
  Future<void> setLanguage(String lang) async => language = lang;
}

void main() {
  test('legacy saved English is migrated to the only supported UI locale', () {
    final storage = _LanguageStorage('en');
    final container = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    expect(container.read(localeProvider), const Locale('ar'));
    expect(storage.language, 'ar');
    expect(AppLocalizations.supportedLocales, const [Locale('ar')]);
  });

  test('legacy locale writes cannot switch the UI away from Arabic', () async {
    final storage = _LanguageStorage('ar');
    final container = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);

    await container.read(localeProvider.notifier).setLocale(const Locale('en'));

    expect(container.read(localeProvider), const Locale('ar'));
    expect(storage.language, 'ar');
  });

  testWidgets('an English device still resolves Arabic UI and RTL', (
    tester,
  ) async {
    tester.platformDispatcher.localeTestValue = const Locale('en', 'US');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    final storage = _LanguageStorage('en');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
        child: Consumer(
          builder: (context, ref, child) => MaterialApp(
            locale: ref.watch(localeProvider),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Builder(
              builder: (context) {
                expect(Localizations.localeOf(context), const Locale('ar'));
                expect(Directionality.of(context), TextDirection.rtl);
                return Text(AppLocalizations.of(context)!.home);
              },
            ),
          ),
        ),
      ),
    );

    expect(find.text('الرئيسية'), findsOneWidget);
    expect(storage.language, 'ar');
  });
}

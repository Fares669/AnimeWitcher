import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _SignedOutAccount extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

final class _ReaderSettings extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings();

  @override
  Future<void> setSettings(MangaReaderSettings value) async => state = value;
}

void main() {
  testWidgets('a wide window shows the reader options in the reader group', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeWitcherAccountControllerProvider.overrideWith(
            _SignedOutAccount.new,
          ),
          storageServiceProvider.overrideWithValue(MemoryStorageService()),
          mangaReaderSettingsProvider.overrideWith(_ReaderSettings.new),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MoreScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('القارئ').first);
    await tester.pumpAndSettle();

    // The options themselves, not a row that opens them.
    expect(
      find.byKey(const ValueKey<String>('settings-reader-inline')),
      findsOneWidget,
    );
    expect(find.text('وضع القراءة'), findsOneWidget);
    expect(find.text('قص الحواف'), findsOneWidget);
    expect(find.text('قارئ المانجا'), findsNothing);

    // Changed right there.
    final cropSwitch = find.ancestor(
      of: find.text('قص الحواف'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(cropSwitch).value, isFalse);
    await tester.tap(cropSwitch);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(cropSwitch).value, isTrue);
  });
}

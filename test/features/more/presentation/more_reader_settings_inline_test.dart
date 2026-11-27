import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/providers/anime_data_source_settings_provider.dart';
import 'package:animewitcher/features/settings/presentation/app_version_provider.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/features/more/presentation/more_sidebar_shell.dart';
import 'package:animewitcher/features/more/presentation/broadcast_schedule_screen.dart';
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

Future<void> _mountMore(
  WidgetTester tester, {
  required Future<String> Function(Ref) readVersion,
  List<ProviderObserver>? observers,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      observers: observers,
      overrides: [
        animeWitcherAccountControllerProvider.overrideWith(
          _SignedOutAccount.new,
        ),
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
        mangaReaderSettingsProvider.overrideWith(_ReaderSettings.new),
        appVersionProvider.overrideWith(readVersion),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MoreScreen(),
      ),
    ),
  );
  // An unconfigured account pane can keep its disabled button spinner
  // ticking. Mount the layout without waiting for unrelated animations.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

final class _SettingsObserver extends ProviderObserver {
  int playerStarts = 0;
  int artworkStarts = 0;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (context.provider == playerSettingsProvider) playerStarts++;
    if (context.provider == animeDataSourceSettingsProvider) artworkStarts++;
  }
}

void main() {
  testWidgets('a wide window shows the reader options in the reader group', (
    tester,
  ) async {
    await _mountMore(tester, readVersion: (_) async => 'fixture version');

    final sidebar = tester.widget<MoreSidebarShell>(
      find.byType(MoreSidebarShell),
    );
    expect(sidebar.groups.first.items.single.label, 'الحساب');
    expect(find.text('حساب AnimeWitcher'), findsNothing);

    final destinations = sidebar.groups.expand((group) => group.items);
    final seasons = destinations.singleWhere((item) => item.label == 'المواسم');
    final schedule = destinations.singleWhere(
      (item) => item.label == 'جدول البث',
    );
    expect(schedule.icon, seasons.icon);
    expect(schedule.icon, Icons.calendar_month_rounded);
    expect(
      schedule.builder(tester.element(find.byType(MoreSidebarShell))),
      isA<BroadcastScheduleScreen>(),
    );

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
  testWidgets('wide More defers each settings provider until its pane opens', (
    tester,
  ) async {
    var versionStarts = 0;
    final providers = _SettingsObserver();
    await _mountMore(
      tester,
      observers: [providers],
      readVersion: (_) async {
        versionStarts++;
        return 'fixture version';
      },
    );

    void verify(int player, int artwork, int version) {
      expect(
        (providers.playerStarts, providers.artworkStarts, versionStarts),
        (player, artwork, version),
      );
    }

    final sidebar = tester.widget<MoreSidebarShell>(
      find.byType(MoreSidebarShell),
    );
    expect(sidebar.groups[2].items.map((item) => item.label), [
      'عام',
      'المشغل',
      'القارئ',
      'التنزيلات',
      'الصور',
      'بيانات التطبيق',
      'حول',
    ]);

    Future<void> open(String label) async {
      final button = find.text(label).first;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    // ACCOUNT_START
    verify(0, 0, 0);
    await open('القارئ');
    expect(
      find.byKey(const ValueKey<String>('settings-reader-inline')),
      findsOneWidget,
    );
    // READER_START
    verify(0, 0, 0);

    await open('المشغل');
    expect(find.text('المشغل الافتراضي'), findsOneWidget);
    // PLAYER_START
    verify(1, 0, 0);

    await open('الصور');
    expect(find.text('صور الحلقات'), findsOneWidget);
    // ART_START
    verify(1, 1, 0);

    await open('حول');
    expect(find.text('fixture version'), findsOneWidget);
    // ABOUT_START
    verify(1, 1, 1);
  });
}

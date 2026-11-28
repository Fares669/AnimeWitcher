import 'package:animewitcher/core/providers/anime_data_source_settings_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/settings/presentation/app_version_provider.dart';
import 'package:animewitcher/features/settings/presentation/cache_provider.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/features/settings/presentation/settings_screen.dart';
import 'package:animewitcher/features/settings/presentation/widgets/settings_dialogs.dart';
import 'package:animewitcher/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/custom_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _SettingsStorage extends MemoryStorageService {
  @override
  Future<void> setPlayerSetting(String key, dynamic value) async {
    settings[key] = value;
  }

  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) =>
      (settings[key] ?? defaultValue) as T?;
}

final class _SettingsObserver extends ProviderObserver {
  int imageStarts = 0;
  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (context.provider == animeDataSourceSettingsProvider) imageStarts++;
  }
}

Future<void> _mount(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
                child: const Text('fixture home'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('fixture home'));
  await tester.pumpAndSettle();
}

Finder _group(String title) => find.byWidgetPredicate(
  (widget) => widget is SettingsGroup && widget.title == title,
);

final _scrollable = find.descendant(
  of: find.byType(SettingsScreen),
  matching: find.byType(Scrollable),
);

void main() {
  testWidgets(
    'Arabic Settings defers offscreen sections and keeps route actions live',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 660));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = _SettingsStorage();
      final observer = _SettingsObserver();
      var versionStarts = 0;
      var cacheStarts = 0;
      final container = ProviderContainer(
        observers: [observer],
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          appVersionProvider.overrideWith((_) async {
            versionStarts++;
            return 'fixture version';
          }),
          cacheSizeProvider.overrideWith((_) async {
            cacheStarts++;
            return 123;
          }),
        ],
      );
      addTearDown(container.dispose);
      await _mount(tester, container);

      expect(Directionality.of(tester.element(_scrollable)), TextDirection.rtl);
      expect(_group('عام'), findsOneWidget);
      expect((observer.imageStarts, cacheStarts, versionStarts), (0, 0, 0));

      await tester.dragUntilVisible(
        find.text(downloadConcurrencyTitle()),
        _scrollable,
        const Offset(0, -420),
      );
      await tester.ensureVisible(find.text(downloadConcurrencyTitle()));
      await tester.pumpAndSettle();

      final tile = find.widgetWithText(ListTile, downloadConcurrencyTitle());
      final rowFocus = find.descendant(of: tile, matching: find.byType(Focus));
      expect(rowFocus, findsOneWidget);
      final focusChild = tester.widget<Focus>(rowFocus).child;
      final focus = Focus.of(tester.element(find.byWidget(focusChild)));
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      final slider = find.byKey(const ValueKey('download-concurrency-slider'));
      expect(slider, findsOneWidget);
      tester.widget<CustomSlider>(slider).onChanged!(3);
      await tester.pump();
      expect(storage.getDownloadConcurrency(), 1);

      // The dialog's save callback must outlive its scrolled-out launcher.
      final position = tester.state<ScrollableState>(_scrollable).position;
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(_group('التنزيلات'), findsNothing);
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(storage.getDownloadConcurrency(), 3);

      await tester.dragUntilVisible(
        find.text(downloadConcurrencyTitle()),
        _scrollable,
        const Offset(0, -400),
      );
      expect(find.text(downloadConcurrencySubtitle(3)), findsOneWidget);

      await tester.dragUntilVisible(
        find.text('fixture version'),
        _scrollable,
        const Offset(0, -360),
      );
      expect((observer.imageStarts, cacheStarts, versionStarts), (1, 1, 1));
      position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(
        find.text('fixture version'),
        _scrollable,
        const Offset(0, -360),
      );
      // Do not rerun the cache scan when App Data is revisited in this visit.
      expect(cacheStarts, 1);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('fixture home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('visible settings rebuild only for edited preferences', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 3500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = _SettingsStorage();
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        appVersionProvider.overrideWith((_) async => 'fixture version'),
        cacheSizeProvider.overrideWith((_) async => 123),
      ],
    );
    addTearDown(container.dispose);
    await _mount(tester, container);

    final general = _group('عام');
    final downloads = _group('التنزيلات');
    final player = _group('المشغل');
    final currentGeneral = tester.widget<SettingsGroup>(general);
    final currentDownloads = tester.widget<SettingsGroup>(downloads);
    final currentPlayer = tester.widget<SettingsGroup>(player);
    final notifier = container.read(generalSettingsProvider.notifier);

    await notifier.setDownloadConcurrency(3);
    await tester.pumpAndSettle();
    final editedDownloads = tester.widget<SettingsGroup>(downloads);
    expect(editedDownloads, isNot(same(currentDownloads)));
    expect(find.text(downloadConcurrencySubtitle(3)), findsOneWidget);
    expect(tester.widget<SettingsGroup>(general), same(currentGeneral));
    expect(tester.widget<SettingsGroup>(player), same(currentPlayer));

    await notifier.setAutoSelectStreamSource(true);
    await tester.pumpAndSettle();
    expect(storage.settings['stream_source_auto_select'], isTrue);
    expect(_group('عام'), findsOneWidget);
    expect(tester.widget<SettingsGroup>(general), isNot(same(currentGeneral)));
    expect(tester.widget<SettingsGroup>(downloads), same(editedDownloads));
    expect(tester.widget<SettingsGroup>(player), same(currentPlayer));
    expect(
      find.byKey(const ValueKey('settings-quality-priority')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-server-priority')),
      findsOneWidget,
    );
  });
}

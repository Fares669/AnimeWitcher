import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/download_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/settings/presentation/app_version_provider.dart';
import 'package:animewitcher/features/settings/presentation/settings_screen.dart';
import 'package:animewitcher/features/settings/presentation/widgets/settings_dialogs.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/custom_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    DownloadService.configureHoldingQueueForTesting = null;
  });

  testWidgets('Settings downloads group uses sliders for episodes and connections', (
    tester,
  ) async {
    final storage = MemoryStorageService();
    DownloadService.configureHoldingQueueForTesting = (_) async {};
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          appVersionProvider.overrideWith((ref) async => 'test'),
          deviceProfileProvider.overrideWith(
            (ref) async => const DeviceProfile(),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'NotoSansArabic',
            scaffoldBackgroundColor: Colors.black,
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFFEEC60A),
              surface: Color(0xFF1A1A1A),
              onSurface: Color(0xFFE5E7EB),
            ),
          ),
          home: const RepaintBoundary(
            key: ValueKey('settings-download-concurrency'),
            child: SettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.text(downloadConcurrencyTitle()),
      find.byType(Scrollable).first,
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();

    expect(find.text('التنزيلات'), findsWidgets);
    expect(find.text(downloadConcurrencyTitle()), findsOneWidget);
    expect(find.text(downloadConcurrencySubtitle(1)), findsOneWidget);

    await tester.tap(find.text(downloadConcurrencyTitle()));
    await tester.pumpAndSettle();

    final concurrencyFinder = find.byKey(
      const ValueKey('download-concurrency-slider'),
    );
    expect(concurrencyFinder, findsOneWidget);
    var concurrencySlider = tester.widget<CustomSlider>(concurrencyFinder);
    expect(concurrencySlider.min, kDownloadConcurrencyMin.toDouble());
    expect(concurrencySlider.max, kDownloadConcurrencyMax.toDouble());
    expect(
      concurrencySlider.divisions,
      kDownloadConcurrencyMax - kDownloadConcurrencyMin,
    );
    expect(concurrencySlider.value, 1);

    concurrencySlider.onChanged!(3);
    await tester.pump();
    expect(find.text('3 تحميلات في نفس الوقت'), findsOneWidget);
    // Slider movement is provisional until Save, like upstream SkyStream.
    expect(storage.getDownloadConcurrency(), 1);

    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();

    expect(storage.getDownloadConcurrency(), 3);
    expect(find.text(downloadConcurrencySubtitle(3)), findsOneWidget);
    expect(find.text(downloadConcurrencySubtitle(1)), findsNothing);

    await tester.dragUntilVisible(
      find.text(downloadPartsTitle()),
      find.byType(Scrollable).first,
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();

    expect(find.text(downloadPartsTitle()), findsOneWidget);
    expect(find.text(downloadPartsSubtitle(kDownloadPartsAuto)), findsOneWidget);

    await tester.tap(find.text(downloadPartsTitle()));
    await tester.pumpAndSettle();

    final partsFinder = find.byKey(const ValueKey('download-parts-slider'));
    expect(partsFinder, findsOneWidget);
    var partsSlider = tester.widget<CustomSlider>(partsFinder);
    expect(partsSlider.min, kDownloadPartsAuto.toDouble());
    expect(partsSlider.max, kDownloadPartsMax.toDouble());
    expect(partsSlider.divisions, 16);
    expect(partsSlider.value, 0);
    expect(find.text('تلقائي'), findsWidgets);

    partsSlider.onChanged!(4);
    await tester.pump();
    expect(find.text('4 اتصالات متوازية'), findsOneWidget);
    expect(storage.getDownloadParallelParts(), kDownloadPartsAuto);

    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();

    expect(storage.getDownloadParallelParts(), 4);
    expect(find.text(downloadPartsSubtitle(4)), findsOneWidget);

    final artifacts = debugShotDirectory();
    if (artifacts == null) return;

    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('settings-download-concurrency')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/settings_concurrent_downloads.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });

  testWidgets('Settings can turn all download notifications off', (
    tester,
  ) async {
    final storage = MemoryStorageService();
    DownloadService.configureHoldingQueueForTesting = (_) async {};
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          appVersionProvider.overrideWith((ref) async => 'test'),
          deviceProfileProvider.overrideWith(
            (ref) async => const DeviceProfile(),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'NotoSansArabic',
            scaffoldBackgroundColor: Colors.black,
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFFEEC60A),
              surface: Color(0xFF1A1A1A),
              onSurface: Color(0xFFE5E7EB),
            ),
          ),
          home: const RepaintBoundary(
            key: ValueKey('settings-download-notifications'),
            child: SettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.text(downloadNotificationsTitle()),
      find.byType(Scrollable).first,
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        downloadNotificationsSubtitle(DownloadNotificationPrefs.enabled),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(downloadNotificationsTitle()));
    await tester.pumpAndSettle();

    expect(find.text('كل الإشعارات'), findsOneWidget);
    expect(find.text('البدء'), findsOneWidget);
    expect(find.text('الانتهاء'), findsOneWidget);
    expect(find.text('الإيقاف'), findsOneWidget);
    expect(find.text('الإلغاء'), findsOneWidget);
    expect(find.text('التوقف أو الفشل'), findsOneWidget);

    await tester.tap(find.text('كل الإشعارات'));
    await tester.pumpAndSettle();

    expect(
      storage.getDownloadNotificationPrefs(),
      DownloadNotificationPrefs.disabled,
    );

    final artifacts = debugShotDirectory();
    if (artifacts != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('download-notifications-dialog')),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${artifacts.path}/settings_download_notifications.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    await tester.tap(find.text('إغلاق'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        downloadNotificationsSubtitle(DownloadNotificationPrefs.disabled),
      ),
      findsOneWidget,
    );
  });
}

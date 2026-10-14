import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/settings/presentation/app_version_provider.dart';
import 'package:animewitcher/features/settings/presentation/settings_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

void main() {
  testWidgets('settings keep download logs without app-wide logging controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(MemoryStorageService()),
          appVersionProvider.overrideWith((ref) async => 'test'),
          deviceProfileProvider.overrideWith(
            (ref) async => const DeviceProfile(),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('settings-app-diagnostic-log')),
      findsNothing,
    );
    expect(find.text('App diagnostic log'), findsNothing);
    expect(find.text('سجل التطبيق'), findsNothing);
    await tester.dragUntilVisible(
      find.text('سجل التنزيلات (Log)'),
      find.byType(Scrollable).first,
      const Offset(0, -250),
    );
    expect(find.text('سجل التنزيلات (Log)'), findsOneWidget);
  });
}

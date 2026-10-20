import 'package:animewitcher/features/settings/presentation/widgets/taskbar_customization_dialog.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('customization omits legacy More and keeps normal tabs editable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => showTaskbarCustomizationDialog(
                  context,
                  ref,
                  ['settings', 'downloads', 'home'],
                  {'settings'},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('المزيد'), findsNothing);
    expect(find.text('لا يمكن إخفاؤها'), findsNothing);
    expect(find.byType(Switch), findsNWidgets(5));
    for (final toggle in tester.widgetList<Switch>(find.byType(Switch))) {
      expect(toggle.onChanged, isNotNull);
    }
    expect(tester.takeException(), isNull);
  });
}

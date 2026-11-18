import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/features/more/presentation/broadcast_schedule_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the schedule uses the active Witanime catalog', (tester) async {
    final requests = <String>[];
    final provider = WitanimeProvider((uri, {cancelToken}) async {
      requests.add(uri.path);
      return '''
        <main>
          ${['السبت', 'الأحد', 'الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة'].map((day) => '<section><h2>$day</h2>'
          '<a href="/anime/schedule-test"><h3>Witanime Schedule</h3></a>'
          '</section>').join()}
        </main>
      ''';
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [activeProviderProvider.overrideWithValue(provider)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BroadcastScheduleScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(requests, ['/schedule']);
    expect(find.text('Witanime Schedule'), findsWidgets);
  });
}

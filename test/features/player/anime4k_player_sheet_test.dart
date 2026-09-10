import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/presentation/widgets/anime4k_player_sheet.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<Anime4kMode>> _open(
  WidgetTester tester, {
  Anime4kMode mode = Anime4kMode.a,
}) async {
  final chosen = <Anime4kMode>[];
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Anime4kPlayerSheet.show(
            context: context,
            currentMode: mode,
            onModeSelected: chosen.add,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return chosen;
}

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('builds without throwing', (tester) async {
    // A regex whose lookbehind was never closed once threw on every build of
    // this panel, and a thrown widget paints as a plain grey box in release —
    // which reads as a broken picture rather than a crash. Nothing pumped
    // this widget at the time.
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _open(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('ANIME4K'), findsOneWidget);
  });

  testWidgets('lists off and every mode, and nothing else', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _open(tester);

    expect(find.text('إيقاف'), findsOneWidget);
    for (final mode in Anime4kMode.values) {
      if (mode == Anime4kMode.off) continue;
      expect(find.text('النمط ${mode.label}'), findsOneWidget);
    }

    // Setting the feature up belongs in settings; mid-episode the only
    // question is which mode is running.
    expect(find.text('الجودة'), findsNothing);
    expect(find.textContaining('للمقارنة'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('describes the mode that is running', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _open(tester, mode: Anime4kMode.b);
    expect(find.textContaining('ترميم أخف'), findsOneWidget);
  });

  testWidgets('choosing a mode reports it and closes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final chosen = await _open(tester);

    await tester.tap(find.text('النمط C'));
    await tester.pumpAndSettle();

    expect(chosen, <Anime4kMode>[Anime4kMode.c]);
    expect(find.text('ANIME4K'), findsNothing, reason: 'the menu closed');
  });

  testWidgets('off is one of the choices here', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // In settings a switch owns on and off, because that is where the feature
    // is set up. In a menu of modes, off is simply the last one.
    final chosen = await _open(tester);
    await tester.tap(find.text('إيقاف'));
    await tester.pumpAndSettle();
    expect(chosen, <Anime4kMode>[Anime4kMode.off]);
  });
}

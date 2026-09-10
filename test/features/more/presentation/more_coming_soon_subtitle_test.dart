import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';

class _SignedOutAccount extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return const AnimeWitcherAccountSnapshot();
  }
}

Future<void> _loadWalkthroughFonts() => TestFonts.loadWalkthroughFonts();

void main() {
  testWidgets('more screen describes coming soon as unaired titles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeWitcherAccountControllerProvider.overrideWith(
            _SignedOutAccount.new,
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
              surface: Color(0xFF000000),
              onSurface: Color(0xFFE5E7EB),
            ),
          ),
          home: const RepaintBoundary(
            key: ValueKey('more-coming-soon-shot'),
            child: MoreScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('القادم قريبًا'), findsOneWidget);
    expect(
      find.text('أنميات لم يتم بثها بعد حسب بيانات AnimeWitcher'),
      findsOneWidget,
    );
    expect(find.textContaining('الموسم القادم'), findsNothing);

    final artifacts = debugShotDirectory();
    if (artifacts == null) return;

    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('more-coming-soon-shot')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/coming_soon_menu_unaired_copy.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}

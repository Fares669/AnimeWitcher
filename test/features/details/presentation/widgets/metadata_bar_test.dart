import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/test_fonts.dart';
import '../../../../support/debug_shots.dart';

void main() {
  testWidgets('header metadata shows the compact poster-side rating', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            brightness: Brightness.dark,
            colorScheme: const ColorScheme.dark(primary: Color(0xFFEEC60A)),
          ),
          home: Scaffold(
            body: MetadataBar(
              item: MultimediaItem(
                title: 'Bleach',
                url: 'https://animewitcher.com/anime/bleach',
                posterUrl: '',
                contentRating: '+17',
                syncData: const <String, String>{
                  'awMalScore': '9.08',
                  'awScore': '8.5',
                  'awState': 'مستمر',
                  'awSeason': 'صيف 2026',
                  'awType': 'مسلسل',
                  'awEpisodes': '10',
                  'awAge': '+17',
                },
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('9.08'), findsNothing);
    expect(find.text('8.5'), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.text('+17'), findsOneWidget);
    expect(find.text('مسلسل'), findsOneWidget);

    final loaded = await tester.runAsync(TestFonts.loadWalkthroughFonts);
    if (loaded != true) return;
    final artifacts = debugShotDirectory();
    if (artifacts == null) return;
    const shotKey = ValueKey<String>('metadata-bar-with-rating');
    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(
          key: shotKey,
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
                surface: Color(0xFF111111),
                onSurface: Color(0xFFE5E7EB),
              ),
            ),
            home: Scaffold(
              backgroundColor: Colors.black,
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: MetadataBar(
                  item: MultimediaItem(
                    title: 'Bleach',
                    url: 'https://animewitcher.com/anime/bleach',
                    posterUrl: '',
                    contentRating: '+17',
                    syncData: const <String, String>{
                      'awMalScore': '9.08',
                      'awScore': '8.5',
                      'awState': 'مستمر',
                      'awShowTime': 'السبت',
                      'awSeason': 'صيف 2026',
                      'awType': 'مسلسل',
                      'awEpisodes': '10',
                      'awAge': '+17',
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(shotKey),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/details_header_metadata_with_rating.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}

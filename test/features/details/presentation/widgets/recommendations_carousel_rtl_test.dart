import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item(String title, String id) {
  return MultimediaItem(
    title: title,
    url: 'https://example.test/$id',
    posterUrl: '',
  );
}

void main() {
  testWidgets('related and more-like-this rails start on the right', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ListView(
            children: [
              RecommendationsCarousel(
                title: 'ذات صلة',
                items: [
                  _item('RelatedOne', 'r1'),
                  _item('RelatedTwo', 'r2'),
                  _item('RelatedThree', 'r3'),
                ],
                showRelationBadge: true,
                onItemTap: (_) {},
              ),
              RecommendationsCarousel(
                items: [
                  _item('MoreOne', 'm1'),
                  _item('MoreTwo', 'm2'),
                  _item('MoreThree', 'm3'),
                ],
                onItemTap: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('ذات صلة'), findsOneWidget);
    expect(find.text('المزيد مثل هذا'), findsOneWidget);

    final relatedFirst = tester.getTopLeft(
      find.byKey(const ValueKey('ذات صلة-rail-0')),
    );
    final relatedLast = tester.getTopLeft(
      find.byKey(const ValueKey('ذات صلة-rail-2')),
    );
    expect(relatedFirst.dx, greaterThan(relatedLast.dx));

    final moreFirst = tester.getTopLeft(
      find.byKey(const ValueKey('more-like-this-rail-0')),
    );
    final moreLast = tester.getTopLeft(
      find.byKey(const ValueKey('more-like-this-rail-2')),
    );
    expect(moreFirst.dx, greaterThan(moreLast.dx));
  });

  testWidgets('related rails screenshot for walkthrough', (tester) async {
    await tester.runAsync(_loadWalkthroughFonts);

    const size = Size(390, 920);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
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
        home: Scaffold(
          backgroundColor: Colors.black,
          body: RepaintBoundary(
            key: const ValueKey('related-rails-shot'),
            child: ColoredBox(
              color: Colors.black,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  RecommendationsCarousel(
                    title: 'ذات صلة',
                    items: [
                      _item('RelatedOne', 'r1'),
                      _item('RelatedTwo', 'r2'),
                      _item('RelatedThree', 'r3'),
                    ],
                    showRelationBadge: true,
                    onItemTap: (_) {},
                  ),
                  const SizedBox(height: 24),
                  RecommendationsCarousel(
                    items: [
                      _item('MoreOne', 'm1'),
                      _item('MoreTwo', 'm2'),
                      _item('MoreThree', 'm3'),
                    ],
                    onItemTap: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final relatedFirst = tester.getTopLeft(
      find.byKey(const ValueKey('ذات صلة-rail-0')),
    );
    final relatedLast = tester.getTopLeft(
      find.byKey(const ValueKey('ذات صلة-rail-2')),
    );
    expect(relatedFirst.dx, greaterThan(relatedLast.dx));

    final artifacts = Directory('/opt/cursor/artifacts');
    if (!artifacts.existsSync()) {
      return;
    }

    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('related-rails-shot')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/related_more_like_this_rtl.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}

Future<ByteData> _fontBytes(String path) async {
  return ByteData.sublistView(await File(path).readAsBytes());
}

Future<void> _loadWalkthroughFonts() async {
  const arabicRegular =
      '/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf';
  if (!File(arabicRegular).existsSync()) return;
  await (FontLoader('NotoSansArabic')
        ..addFont(_fontBytes(arabicRegular))
        ..addFont(
          _fontBytes('/usr/share/fonts/truetype/noto/NotoSansArabic-Bold.ttf'),
        ))
      .load();
  await (FontLoader('Roboto')
        ..addFont(
          _fontBytes(
            '/opt/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
          ),
        )
        ..addFont(
          _fontBytes(
            '/opt/flutter/bin/cache/artifacts/material_fonts/Roboto-Bold.ttf',
          ),
        ))
      .load();
}

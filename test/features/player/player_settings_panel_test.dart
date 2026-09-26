import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    bool anime4k = true,
    bool resize = true,
    bool speed = true,
    ValueChanged<Anime4kMode>? onMode,
    ValueChanged<int>? onResize,
    ValueChanged<double>? onSpeed,
    List<PlayerPanelChoice> quality = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PlayerSettingsPanel(
              showAnime4k: anime4k,
              anime4kMode: Anime4kMode.a,
              onAnime4kMode: onMode ?? (_) {},
              showResize: resize,
              resizeIndex: 0,
              resizeLabels: const ['Fit', 'Zoom', 'Stretch'],
              onResize: onResize ?? (_) {},
              showSpeed: speed,
              speed: 1.0,
              maxSpeed: 2.0,
              onSpeed: onSpeed ?? (_) {},
              qualityLabel: quality.isEmpty ? null : '1080p · PD',
              loadQualityChoices: () async => quality,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('picture tab offers the Anime4K models, off, and the sizes', (
    tester,
  ) async {
    Anime4kMode? mode;
    int? size;
    await pump(tester, onMode: (m) => mode = m, onResize: (i) => size = i);
    expect(find.text('الصورة'), findsOneWidget);
    expect(find.text('السرعة'), findsOneWidget);
    expect(find.text('A + A'), findsOneWidget);
    await tester.tap(find.text('إيقاف'));
    expect(mode, Anime4kMode.off);
    // Size is a row showing its value; the list opens from it.
    expect(find.text('Fit'), findsOneWidget);
    await tester.tap(find.text('الحجم'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zoom'));
    await tester.pumpAndSettle();
    expect(size, 1);
    // Choosing returns to the rows.
    expect(find.text('Anime4K'), findsOneWidget);
  });

  testWidgets('speed tab lists speeds up to the source maximum', (
    tester,
  ) async {
    double? speed;
    await pump(tester, onSpeed: (s) => speed = s);
    await tester.tap(find.text('السرعة'));
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsOneWidget);
    expect(find.text('2x'), findsOneWidget);
    await tester.tap(find.text('1.25x'));
    expect(speed, 1.25);
  });

  testWidgets('a tab with nothing to change is left out', (tester) async {
    await pump(tester, anime4k: false, resize: false);
    expect(find.text('الصورة'), findsNothing);
    expect(find.text('السرعة'), findsOneWidget);
    expect(
      PlayerSettingsPanel.hasContent(
        showAnime4k: false,
        showResize: false,
        showSpeed: false,
      ),
      isFalse,
    );
  });

  testWidgets('quality lists the loaded sources and switches between them', (
    tester,
  ) async {
    String? chosen;
    await pump(
      tester,
      quality: [
        PlayerPanelChoice(
          label: '1080p · PD',
          selected: true,
          onTap: () => chosen = '1080p · PD',
        ),
        PlayerPanelChoice(
          label: '720p · MF',
          selected: false,
          onTap: () => chosen = '720p · MF',
        ),
      ],
    );
    expect(find.text('الجودة'), findsOneWidget);
    expect(find.text('1080p · PD'), findsOneWidget);
    await tester.tap(find.text('الجودة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('720p · MF'));
    await tester.pumpAndSettle();
    expect(chosen, '720p · MF');
  });
}

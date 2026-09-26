import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('quality choices are grouped under quality headers', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: PlayerSettingsPanel(
              showAnime4k: false,
              anime4kMode: Anime4kMode.off,
              onAnime4kMode: (_) {},
              showResize: false,
              resizeIndex: 0,
              resizeLabels: const <String>['Fit'],
              onResize: (_) {},
              showSpeed: false,
              speed: 1,
              maxSpeed: 2,
              onSpeed: (_) {},
              qualityLabel: '1080p · PD',
              loadQualityChoices: () async => <PlayerPanelChoice>[
                PlayerPanelChoice(
                  label: 'PD',
                  sectionLabel: '1080p',
                  selected: true,
                  onTap: () {},
                ),
                PlayerPanelChoice(
                  label: 'MF2',
                  sectionLabel: '1080p',
                  selected: false,
                  onTap: () {},
                ),
                PlayerPanelChoice(
                  label: 'PD',
                  sectionLabel: '720p',
                  selected: false,
                  onTap: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('1080p · PD'));
    await tester.pumpAndSettle();

    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('MF2'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline_rounded), findsNWidgets(3));
  });
}

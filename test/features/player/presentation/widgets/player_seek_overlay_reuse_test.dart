import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/player_platform_service.dart';
import 'package:animewitcher/features/player/presentation/widgets/animewitcher_player_controls.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_ltr.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;

class _LocalMediaKit extends mk.PlatformPlayer {
  _LocalMediaKit() : super(configuration: const mk.PlayerConfiguration()) {
    state = state.copyWith(
      playing: true,
      position: const Duration(minutes: 3),
      duration: const Duration(minutes: 24),
    );
  }

  void step(Duration by) {
    final position = state.position + by;
    state = state.copyWith(position: position);
    positionController.add(position);
  }
}

class _Controller extends PlayerController {
  _Controller(this.backend, this.seeks);

  final _LocalMediaKit backend;
  final List<Duration> seeks;

  @override
  PlayerState build() => const PlayerState(
    isSeekable: true,
    uiPhase: PlaybackUiPhase(kind: PlaybackUiPhaseKind.idle),
  );

  @override
  Future<double> getVolumeLevel() async => 0.25;

  @override
  Future<void> seekRelative(Duration amount, {bool fast = false}) async {
    seeks.add(amount);
    backend.step(amount);
  }
}

class _Settings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

Finder _kick(String label) => find.byWidgetPredicate((widget) {
  if (widget is! FadeTransition) return false;
  final scale = widget.child;
  if (scale is! ScaleTransition) return false;
  final row = scale.child;
  return row is Row && row.children.any((w) => w is Text && w.data == label);
}, description: 'seek animation with the cumulative label $label');

void main() {
  testWidgets(
    'seek feedback reuses its curves without changing player input or Back',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger = tester.binding.defaultBinaryMessenger;
      for (final channel in const [
        MethodChannel('com.yosemiteyss.flutter_volume_controller/method'),
        MethodChannel('com.yosemiteyss.flutter_volume_controller/event'),
      ]) {
        messenger.setMockMethodCallHandler(channel, (_) async => null);
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }

      final backend = _LocalMediaKit();
      final player = mk.Player(platformPlayer: backend);
      final seeks = <Duration>[];
      final controls = GlobalKey<AnimeWitcherPlayerControlsState>();
      final navigator = GlobalKey<NavigatorState>();
      const routeLabel = 'open fixture player';
      final fades = Set<Animation<double>>.identity();
      final scales = Set<Animation<double>>.identity();

      Future<void> open() async {
        await tester.tap(find.text(routeLabel));
        await tester.pumpAndSettle();
        controls.currentState!.showControls();
        await tester.pumpAndSettle();
      }

      Future<void> tapSeek(bool left) async {
        final button = find.byTooltip(
          left ? 'إرجاع 10 ثوانٍ' : 'تقديم 10 ثوانٍ',
        );
        expect(button.hitTestable(), findsOneWidget);
        await tester.tap(button.hitTestable());
        await tester.pump();
      }

      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              deviceProfileProvider.overrideWithValue(
                const AsyncData(DeviceProfile(isTv: false)),
              ),
              playerControllerProvider.overrideWith(
                () => _Controller(backend, seeks),
              ),
              playerSettingsProvider.overrideWith(_Settings.new),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              locale: const Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => navigator.currentState!.push(
                      MaterialPageRoute<void>(
                        builder: (context) => Scaffold(
                          body: PlayerLtr(
                            child: AnimeWitcherPlayerControls(
                              key: controls,
                              player: player,
                              platformService: PlayerPlatformService(
                                nativePip: false,
                              ),
                              title: 'Offline seek fixture',
                              onBackPointer: () =>
                                  navigator.currentState!.pop(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    child: const Text(routeLabel),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await open();

        var cumulative = 0;
        const moves = [false, false, true, true, true, false, false, false];
        for (final left in moves) {
          cumulative += left ? -10 : 10;
          final label = cumulative > 0 ? '+$cumulative' : '$cumulative';
          await tapSeek(left);
          Row? firstRow;
          for (var frame = 0; frame <= 12; frame++) {
            if (frame != 0) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            final finder = _kick(label);
            expect(finder, findsOneWidget);
            final fade = tester.widget<FadeTransition>(finder);
            final scale = fade.child! as ScaleTransition;
            fades.add(fade.opacity);
            scales.add(scale.scale);
            final row = scale.child! as Row;
            firstRow ??= row;
            expect(identical(row, firstRow), isTrue);
            final interval = (frame * 16 / 180).clamp(0.0, 1.0).toDouble();
            expect(
              fade.opacity.value,
              closeTo(Curves.easeOutCubic.transform(interval), 1e-9),
            );
            expect(
              scale.scale.value,
              closeTo(0.94 + 0.06 * Curves.easeOut.transform(interval), 1e-9),
            );
            final lookingLeft = cumulative < 0 || (cumulative == 0 && left);
            expect(
              tester.getCenter(finder).dx,
              lookingLeft ? lessThan(600.0) : greaterThan(600.0),
            );
          }
        }
        expect(fades, hasLength(1));
        expect(scales, hasLength(1));
        expect(seeks, [
          for (final left in moves) Duration(seconds: left ? -10 : 10),
        ]);
        expect(player.state.position, const Duration(minutes: 3, seconds: 20));

        await tester.pump(const Duration(seconds: 1));
        expect(_kick('+20'), findsNothing);
        await tapSeek(true);
        expect(_kick('-10'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 48));
        final back = MaterialLocalizations.of(controls.currentContext!)
            .backButtonTooltip;
        await tester.tap(find.byTooltip(back).hitTestable());
        await tester.pumpAndSettle();
        expect(find.text(routeLabel), findsOneWidget);
        expect(find.byType(AnimeWitcherPlayerControls), findsNothing);
        expect(_kick('-10'), findsNothing);

        await open();
        expect(_kick('-10'), findsNothing);
        await tapSeek(false);
        expect(_kick('+10'), findsOneWidget);
        expect(player.state.position, const Duration(minutes: 3, seconds: 20));
        expect(seeks, [
          for (final left in moves) Duration(seconds: left ? -10 : 10),
          const Duration(seconds: -10),
          const Duration(seconds: 10),
        ]);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
      }
      expect(tester.takeException(), isNull);
    },
  );
}

import 'dart:async';
import 'dart:ui' as ui;

import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_ltr.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_subtitle_overlay.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart'; // ignore: deprecated_member_use
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as media;
import 'package:media_kit_video/media_kit_video.dart';

import '../../../support/memory_storage_service.dart';

class _MemorySettings extends MemoryStorageService {
  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) =>
      (settings[key] as T?) ?? defaultValue;

  @override
  Future<void> setPlayerSetting(String key, dynamic value) async {
    settings[key] = value;
  }
}

class _AppPlayer extends PlayerController {
  @override
  PlayerState build() => const PlayerState();

  void setVideoView(bool enabled) =>
      state = state.copyWith(useExoPlayer: enabled);
}

class _MediaPlayer extends Fake implements media.Player {
  _MediaPlayer(List<String> first)
    : _state = media.PlayerState(subtitle: first);

  final cues = StreamController<List<String>>.broadcast(sync: true);
  media.PlayerState _state;

  @override
  media.PlayerState get state => _state;
  @override
  media.PlayerStream get stream => _MediaStreams(cues.stream);

  void emit(List<String> lines) {
    _state = _state.copyWith(subtitle: lines);
    cues.add(lines);
  }
}

class _MediaStreams extends Fake implements media.PlayerStream {
  _MediaStreams(this.subtitle);

  @override
  final Stream<List<String>> subtitle;
}

class _VideoController extends Fake implements VideoController {
  _VideoController(this.player);

  @override
  final media.Player player;
}

void main() {
  for (final locale in const [Locale('ar'), Locale('en')]) {
    testWidgets(
      'mounted subtitle layer updates only its changed inputs ($locale)',
      (tester) async {
        final arabic = locale.languageCode == 'ar';
        final first = arabic
            ? 'سطر الترجمة الأول\nالسطر الثاني'
            : 'First caption\nSecond line';
        final second = arabic ? 'ترجمة جديدة' : 'Another caption';
        final initialCue = [
          for (final line in first.split('\n')) ' $line ',
          ' ',
        ];
        final player = _MediaPlayer(initialCue);
        final controller = _VideoController(player);
        final visible = ValueNotifier(false);
        final storage = _MemorySettings();
        final repaint = GlobalKey();
        final appDirection = GlobalKey();
        final viewport = Size(arabic ? 420 : 700, 430);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const font = 'Readex Pro';
        await tester.runAsync(
          () =>
              (FontLoader(font)..addFont(
                    rootBundle.load(
                      'assets/fonts/readex_pro/ReadexPro-Regular.ttf',
                    ),
                  ))
                  .load(),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playerControllerProvider.overrideWith(_AppPlayer.new),
              settingsRepositoryProvider.overrideWithValue(
                SettingsRepository(storage),
              ),
            ],
            child: MaterialApp(
              locale: locale,
              // The app ships Arabic. Exercise the same renderer under a
              // Material-only English shell for the LTR comparison.
              localizationsDelegates: arabic
                  ? AppLocalizations.localizationsDelegates
                  : null,
              supportedLocales: arabic
                  ? AppLocalizations.supportedLocales
                  : const [Locale('en')],
              theme: ThemeData(fontFamily: font),
              home: Scaffold(
                body: Builder(
                  key: appDirection,
                  builder: (context) => PlayerLtr(
                    child: RepaintBoundary(
                      key: repaint,
                      child: Stack(
                        children: [
                          const Positioned.fill(
                            child: ColoredBox(color: Color(0xFF26374B)),
                          ),
                          PlayerSubtitleOverlay(
                            controller: controller,
                            controlsVisible: visible,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        final overlay = find.byType(PlayerSubtitleOverlay);
        final container = ProviderScope.containerOf(tester.element(overlay));
        await container.read(playerSettingsProvider.future);
        await tester.pumpAndSettle();
        final settings = container.read(playerSettingsProvider.notifier);
        final appPlayer =
            container.read(playerControllerProvider.notifier) as _AppPlayer;
        final subtitle = find.byType(SubtitleView);
        final caption = find.text(first);
        final frames = <String>[];
        Future<void> capture() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(repaint),
          );
          final hash = await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            try {
              final rgba = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              return sha256
                  .convert(
                    rgba.buffer.asUint8List(
                      rgba.offsetInBytes,
                      rgba.lengthInBytes,
                    ),
                  )
                  .toString();
            } finally {
              image.dispose();
            }
          });
          expect(hash, isNotNull);
          frames.add(hash!);
        }

        expect(
          Directionality.of(tester.element(find.byKey(appDirection))),
          arabic ? TextDirection.rtl : TextDirection.ltr,
        );
        expect(Directionality.of(tester.element(subtitle)), TextDirection.ltr);
        expect(caption, findsOneWidget);
        expect(player.cues.hasListener, isTrue);
        final initialY = tester.getBottomLeft(subtitle).dy;
        expect(viewport.height - initialY, closeTo(20, 0.01));
        await capture();

        var controlViews = 0, controlStyles = 0, controlTexts = 0;
        var prefViews = 0, prefStyles = 0, prefTexts = 0;
        final overlayState = tester.state<SubtitleViewState>(subtitle);
        for (var i = 0; i < 6; i++) {
          final previous = tester.widget<SubtitleView>(subtitle);
          final text = tester.widget<Text>(caption);
          visible.value = !visible.value;
          await tester.pumpAndSettle();
          final current = tester.widget<SubtitleView>(subtitle);
          if (!identical(previous, current)) controlViews++;
          if (!identical(
            previous.configuration.style,
            current.configuration.style,
          )) {
            controlStyles++;
          }
          if (!identical(text, tester.widget<Text>(caption))) controlTexts++;
          expect(tester.state(subtitle), same(overlayState));
          expect(
            tester.getBottomLeft(subtitle).dy,
            closeTo(initialY - (visible.value ? 112 : 0), 0.01),
          );
          if (i < 2) await capture();
        }
        for (var i = 0; i < 6; i++) {
          final previous = tester.widget<SubtitleView>(subtitle);
          final text = tester.widget<Text>(caption);
          await settings.setShowRemainingTime(i.isEven);
          await tester.pumpAndSettle();
          final current = tester.widget<SubtitleView>(subtitle);
          if (!identical(previous, current)) prefViews++;
          if (!identical(
            previous.configuration.style,
            current.configuration.style,
          )) {
            prefStyles++;
          }
          if (!identical(text, tester.widget<Text>(caption))) prefTexts++;
          expect(storage.settings['player_show_remaining'], i.isEven);
          expect(tester.state(subtitle), same(overlayState));
          expect(tester.getBottomLeft(subtitle).dy, closeTo(initialY, 0.01));
        }
        await capture();

        final oldStyle = tester
            .widget<SubtitleView>(subtitle)
            .configuration
            .style;
        await settings.setSubtitleSettings(28, 0xFFF7DD66, 0xFF122045, 0.6);
        await tester.pumpAndSettle();
        final newStyle = tester
            .widget<SubtitleView>(subtitle)
            .configuration
            .style;
        expect(tester.state(subtitle), same(overlayState));
        expect(newStyle, isNot(same(oldStyle)));
        expect(newStyle.fontSize, 28);
        expect(newStyle.color, const Color(0xFFF7DD66));
        expect(
          newStyle.backgroundColor,
          const Color(0xFF122045).withValues(alpha: 0.6),
        );
        expect(storage.settings['player_sub_size'], 28);
        expect(storage.settings['player_sub_color'], 0xFFF7DD66);
        expect(storage.settings['player_sub_bg'], 0xFF122045);
        expect(storage.settings['player_sub_bg_opacity'], 0.6);
        await capture();

        // A restored position uses the same persisted scale after a resize.
        await storage.setPlayerSetting('player_sub_pos', 80.0);
        container.invalidate(playerSettingsProvider);
        await container.read(playerSettingsProvider.future);
        await tester.pumpAndSettle();
        tester.view.physicalSize = Size(viewport.width + 40, 500);
        await tester.pumpAndSettle();
        expect(tester.getBottomLeft(subtitle).dy, closeTo(400, 0.01));
        expect(
          tester.widget<SubtitleView>(subtitle).configuration.style,
          newStyle,
        );
        expect(tester.state(subtitle), same(overlayState));
        await capture();

        player.emit([' $second ', '']);
        await tester.pumpAndSettle();
        expect(caption, findsNothing);
        expect(find.text(second), findsOneWidget);
        await capture();
        player.emit([' ', '']);
        await tester.pumpAndSettle();
        expect(tester.state<SubtitleViewState>(subtitle).subtitle, [' ', '']);
        expect(find.text(second), findsNothing);
        await capture();

        // ExoPlayer/AVPlayer render their own captions. No hidden MediaKit
        // subtitle subscription may survive an engine switch.
        appPlayer.setVideoView(true);
        await tester.pumpAndSettle();
        expect(subtitle, findsNothing);
        expect(player.cues.hasListener, isFalse);
        player.emit(initialCue);
        appPlayer.setVideoView(false);
        await tester.pumpAndSettle();
        expect(caption, findsOneWidget);
        expect(player.cues.hasListener, isTrue);
        expect(tester.state(subtitle), isNot(same(overlayState)));
        await capture();
        expect(frames[0], frames[2]);
        expect(frames[0], frames[3]);
        expect(frames[0], isNot(frames[1]));
        expect(frames[2], isNot(frames[4]));
        expect(frames[6], isNot(frames[7]));
        expect(tester.takeException(), isNull);
        debugPrint(
          'C21_SUBTITLE ${locale.languageCode} controls=$controlViews/$controlStyles/$controlTexts prefs=$prefViews/$prefStyles/$prefTexts rgba=${frames.join(',')}',
        );
        expect((controlViews, controlStyles, controlTexts), (0, 0, 0));
        expect((prefViews, prefStyles, prefTexts), (0, 0, 0));

        await tester.pumpWidget(const SizedBox.shrink());
        expect(player.cues.hasListener, isFalse);
        visible.dispose();
        await player.cues.close();
      },
    );
  }
}

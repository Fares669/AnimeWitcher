import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/player_platform_service.dart';
import 'package:animewitcher/features/player/presentation/widgets/animewitcher_player_controls.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_ltr.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/features/details/presentation/source_picker.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_settings_panel.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:crypto/crypto.dart';
// Match the compatibility Material API used by PlayerSettingsPanel.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' as mk;

void main() {
  _addSourceProjectionTest();
  _addPlayerRouteTest();
  testWidgets('player picker shows only available language and sub/dub modes', (
    tester,
  ) async {
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
                  language: StreamSourceLanguage.arabic,
                  audioType: StreamSourceAudioType.subtitles,
                  onTap: () {},
                ),
                PlayerPanelChoice(
                  label: 'MF',
                  sectionLabel: '720p',
                  selected: false,
                  language: StreamSourceLanguage.arabic,
                  audioType: StreamSourceAudioType.dubbed,
                  onTap: () {},
                ),
                PlayerPanelChoice(
                  label: 'ST',
                  sectionLabel: '480p',
                  selected: false,
                  language: StreamSourceLanguage.english,
                  audioType: StreamSourceAudioType.subtitles,
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
    expect(
      find.byKey(const ValueKey('player-source-language-arabic')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-source-language-english')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-source-mode-subtitles')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-source-mode-dubbed')),
      findsOneWidget,
    );
    expect(find.text('PD'), findsOneWidget);
    expect(find.text('MF'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('player-source-mode-dubbed')));
    await tester.pumpAndSettle();
    expect(find.text('MF'), findsOneWidget);
    expect(find.text('PD'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('player-source-language-english')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-source-mode-dubbed')),
      findsNothing,
    );
    expect(find.text('ST'), findsOneWidget);
    expect(find.text('MF'), findsNothing);
  });

  testWidgets('quality choices are grouped under quality headers', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Directionality(
            textDirection: TextDirection.rtl,
            child: Center(
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
      ),
    );

    await tester.tap(find.text('1080p · PD'));
    await tester.pumpAndSettle();

    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('MF2'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline_rounded), findsNWidgets(3));
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    final back = find.byIcon(Icons.chevron_left_rounded);
    expect(
      tester.getCenter(back).dx,
      lessThan(tester.getCenter(find.text('الجودة')).dx),
    );
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.text('1080p · PD'), findsOneWidget);
  });
}

final class _CountedChoices extends ListBase<PlayerPanelChoice> {
  _CountedChoices(this._choices);

  final List<PlayerPanelChoice> _choices;
  int reads = 0;

  @override
  int get length => _choices.length;

  @override
  set length(int value) => throw UnsupportedError('one completed snapshot');

  @override
  PlayerPanelChoice operator [](int index) {
    reads++;
    return _choices[index];
  }

  @override
  void operator []=(int index, PlayerPanelChoice value) =>
      throw UnsupportedError('one completed snapshot');
}

Future<String> _panelPixels(WidgetTester tester, GlobalKey key) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return sha256
          .convert(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          )
          .toString();
    } finally {
      image.dispose();
    }
  }))!;
}

void _addSourceProjectionTest() {
  testWidgets('quality source snapshot is reused through rebuild and filtering', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final speed = ValueNotifier<double>(1.0);
    addTearDown(speed.dispose);
    var gate = Completer<List<PlayerPanelChoice>>();
    final selected = <String>[];
    final key = GlobalKey();
    var fetches = 0;
    PlayerPanelChoice choice(
      String label,
      StreamSourceLanguage? language,
      StreamSourceAudioType? mode, {
      bool isSelected = false,
      String quality = '720p',
    }) => PlayerPanelChoice(
      label: label,
      language: language,
      audioType: mode,
      selected: isSelected,
      sectionLabel: quality,
      onTap: () => selected.add(label),
    );
    const ar = StreamSourceLanguage.arabic;
    const en = StreamSourceLanguage.english;
    const unknown = StreamSourceLanguage.unknown;
    const subtitles = StreamSourceAudioType.subtitles;
    const dubbed = StreamSourceAudioType.dubbed;
    final choices = _CountedChoices([
      for (var i = 0; i < 12; i++) ...[
        choice('E-dub-$i', en, dubbed, isSelected: i == 0),
        choice('A-dub-$i', ar, dubbed, isSelected: i == 0),
        choice('E-sub-$i', en, subtitles),
        choice(
          'A-sub-$i',
          ar,
          subtitles,
          isSelected: i == 0,
          quality: i < 4 ? '1080p' : '720p',
        ),
      ],
      // Exercise the old ambiguity rules: a selected null-mode choice may
      // influence language selection but doesn't appear in a typed mode.
      choice('Hidden-format', ar, null, isSelected: true),
      choice('Unknown-mode', unknown, null),
      choice('Hidden-language', null, null, isSelected: true),
    ]);
    final Future<List<PlayerPanelChoice>> Function() load = () {
      fetches++;
      return gate.future;
    };
    final originalTheme = ThemeData.dark();

    await tester.pumpWidget(
      MaterialApp(
        theme: originalTheme,
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: Shortcuts(
                shortcuts: const <ShortcutActivator, Intent>{
                  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
                },
                child: ValueListenableBuilder(
                  valueListenable: speed,
                  builder: (context, value, _) => value == 0
                      ? const SizedBox.shrink()
                      : PlayerSettingsPanel(
                          showAnime4k: false,
                          anime4kMode: Anime4kMode.off,
                          onAnime4kMode: (_) {},
                          showResize: false,
                          resizeIndex: 0,
                          resizeLabels: const ['Fit'],
                          onResize: (_) {},
                          showSpeed: true,
                          speed: value,
                          maxSpeed: 2,
                          onSpeed: (_) {},
                          qualityLabel: '1080p · Fixture',
                          loadQualityChoices: load,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Future<void> tapKey(String suffix) async {
      await tester.tap(find.byKey(ValueKey('player-source-$suffix')));
      await tester.pumpAndSettle();
    }

    List<String?> labels(String startsWith) => tester
        .widgetList<Text>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Text && widget.data?.startsWith(startsWith) == true,
          ),
        )
        .map((text) => text.data)
        .toList();

    Finder getBack() => find.descendant(
      of: find.byType(PlayerSettingsPanel),
      matching: find.byIcon(Icons.chevron_left_rounded),
    );

    await tester.tap(find.text('1080p · Fixture'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(fetches, 1);
    speed.value = 1.5;
    await tester.pump();
    expect(fetches, 1);
    gate.complete(choices);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(labels('A-sub-'), [for (var i = 0; i < 12; i++) 'A-sub-$i']);
    expect(find.text('Hidden-format'), findsNothing);
    expect(find.text('Hidden-language'), findsNothing);
    final headers = [
      for (final text in tester.widgetList<Text>(find.byType(Text)))
        if (text.data == '1080p' || text.data == '720p') text.data,
    ];
    expect(headers, ['1080p', '720p']);
    final initialReads = choices.reads;
    expect(initialReads, choices.length);
    final first = await _panelPixels(tester, key);
    choices.reads = 0;

    for (var i = 0; i < 8; i++) {
      speed.value = i.isEven ? 1.25 : 1.75;
      await tester.pumpAndSettle();
    }
    final tickReads = choices.reads;
    final unchanged = await _panelPixels(tester, key);
    expect(unchanged, first);
    choices.reads = 0;

    await tapKey('mode-dubbed');
    expect(labels('A-dub-'), [for (var i = 0; i < 12; i++) 'A-dub-$i']);
    final arabicDub = await _panelPixels(tester, key);
    await tapKey('language-english');
    // English has only dub selected, defined by the loaded sources.
    expect(labels('E-dub-'), [for (var i = 0; i < 12; i++) 'E-dub-$i']);
    await tapKey('mode-subtitles');
    expect(labels('E-sub-'), [for (var i = 0; i < 12; i++) 'E-sub-$i']);
    final englishSub = await _panelPixels(tester, key);
    await tapKey('language-unknown');
    expect(find.text('Unknown-mode'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-source-mode-dubbed')),
      findsNothing,
    );
    final unknownImage = await _panelPixels(tester, key);
    await tapKey('language-english');
    await tapKey('mode-subtitles');
    final filterReads = choices.reads;

    await tester.tap(getBack());
    await tester.pumpAndSettle();
    expect(find.text('1080p · Fixture'), findsOneWidget);
    await tester.tap(find.text('1080p · Fixture'));
    await tester.pumpAndSettle();
    expect(fetches, 1);
    expect(labels('E-sub-'), [for (var i = 0; i < 12; i++) 'E-sub-$i']);
    final reopened = await _panelPixels(tester, key);
    expect(reopened, englishSub);
    final reentryReads = choices.reads - filterReads;

    final row = find.text('E-sub-0');
    Focus.of(tester.element(row)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selected, ['E-sub-0']);
    expect(find.text('1080p · Fixture'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.text('الجودة'))),
      TextDirection.rtl,
    );
    expect(fetches, 1);
    expect(tester.takeException(), isNull);

    debugPrint(
      'C22_PLAYER_SOURCES entries=${choices.length} initial=$initialReads '
      'ticks=$tickReads filters=$filterReads reentry=$reentryReads '
      'rgba=${[first, arabicDub, englishSub, unknownImage, reopened].join(',')}',
    );
    expect([tickReads, filterReads, reentryReads], [0, 0, 0]);

    // A new top-level panel owns a fresh fetch and retains the empty/error
    // affordance. Returning from that sub-list does not retry behind the UI.
    speed.value = 0;
    await tester.pumpAndSettle();
    gate = Completer<List<PlayerPanelChoice>>();
    speed.value = 1;
    await tester.pumpAndSettle();
    await tester.tap(find.text('1080p · Fixture'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(fetches, 2);
    gate.completeError(StateError('offline source fixture'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد مصادر أخرى لهذه الحلقة'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(selected, ['E-sub-0']);
    await tester.tap(getBack());
    await tester.pumpAndSettle();
    expect(find.text('1080p · Fixture'), findsOneWidget);
    expect(fetches, 2);
    expect(tester.takeException(), isNull);
  });
}

class _RouteSettings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

class _RouteController extends PlayerController {
  static const active = StreamResult(
    url: 'https://offline.test/play',
    source: 'PD (عربي مترجم)',
    quality: '1080p',
  );
  final choices = Completer<List<StreamResult>>();
  final switched = <StreamResult>[];
  int reads = 0;

  @override
  PlayerState build() => const PlayerState(
    currentStream: active,
    uiPhase: PlaybackUiPhase(kind: PlaybackUiPhaseKind.idle),
  );

  @override
  Future<List<StreamResult>> episodeSources() {
    reads++;
    return choices.future;
  }

  @override
  Future<bool> switchToSource(StreamResult source) async {
    switched.add(source);
    state = state.copyWith(currentStream: source);
    return true;
  }

  @override
  Future<double> getVolumeLevel() async => .25;
}

class _RouteMedia extends mk.PlatformPlayer {
  _RouteMedia() : super(configuration: const mk.PlayerConfiguration()) {
    state = state.copyWith(playing: true, duration: const Duration(minutes: 5));
  }
}

void _addPlayerRouteTest() {
  testWidgets('Arabic production player gear delegates the original source', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final messenger = tester.binding.defaultBinaryMessenger;
    for (final channel in const [
      MethodChannel('com.yosemiteyss.flutter_volume_controller/method'),
      MethodChannel('com.yosemiteyss.flutter_volume_controller/event'),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    final media = mk.Player(platformPlayer: _RouteMedia());
    addTearDown(media.dispose);
    final controller = _RouteController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(() => controller),
          playerSettingsProvider.overrideWith(_RouteSettings.new),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerLtr(
              child: AnimeWitcherPlayerControls(
                player: media,
                platformService: PlayerPlatformService(nativePip: false),
                title: 'اختبار المشغّل',
                onBackPointer: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(250, 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playerSettingsButton')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerSettingsPanel), findsOneWidget);
    await tester.tap(find.text('1080p · PD'));
    await tester.pump();
    expect(controller.reads, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    const alternate = StreamResult(
      url: 'https://offline.test/mf',
      source: 'MF (عربي مترجم)',
      quality: '720p',
    );
    controller.choices.complete(const [
      alternate,
      StreamResult(
        url: 'https://offline.test/pd',
        source: 'PD (عربي مترجم)',
        quality: '1080p',
      ),
      StreamResult(
        url: 'https://offline.test/dub',
        source: 'ST (عربي مدبلج)',
        quality: '480p',
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('PD'), findsOneWidget);
    expect(find.text('MF'), findsOneWidget);
    expect(find.text('ST'), findsNothing);
    expect(
      tester.getTopLeft(find.text('PD')).dy,
      lessThan(tester.getTopLeft(find.text('MF')).dy),
    );
    await tester.tap(find.text('MF'));
    await tester.pumpAndSettle();
    expect(controller.switched, [same(alternate)]);
    expect(controller.reads, 1);
    expect(find.text('720p · MF'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

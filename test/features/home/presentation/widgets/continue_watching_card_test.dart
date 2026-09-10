import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/playback_launcher.dart';
import 'package:animewitcher/features/home/presentation/widgets/continue_watching_card.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/test_fonts.dart';
import '../../../../support/debug_shots.dart';

HistoryItem _historyItem() {
  return HistoryItem(
    item: MultimediaItem(
      title: 'Buchigire Reijou wa Houfuku wo Chikaimashita',
      url: 'https://animewitcher.test/watch/abc',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      provider: 'fake.provider',
    ),
    position: 40,
    duration: 100,
    lastEpisodeUrl: 'abc|ep9',
    episode: 9,
    episodeServerName: 'الحلقة 9',
    timestamp: 0,
  );
}

class _RecordingPlaybackLauncher extends PlaybackLauncher {
  _RecordingPlaybackLauncher(super.ref);

  HistoryItem? played;
  int playCalls = 0;

  @override
  Future<void> playFromContinueWatching(
    BuildContext context,
    HistoryItem history,
  ) async {
    playCalls += 1;
    played = history;
  }
}

class _FakeContinueWatching extends ContinueWatchingNotifier {
  final List<String> removed = <String>[];

  @override
  List<HistoryItem> build() => const <HistoryItem>[];

  @override
  Future<void> remove(String url) async {
    removed.add(url);
  }
}

Widget _shell({required Widget child, VoidCallback? onTaskbarTap}) {
  return RepaintBoundary(
    key: const ValueKey('cw-card-shot'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'NotoSansArabic',
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFEEC60A),
          surface: Color(0xFF1A1A1A),
        ),
      ),
      home: Scaffold(
        extendBody: true,
        body: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) =>
                Center(child: SizedBox(width: 280, height: 150, child: child)),
          ),
        ),
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: SizedBox(
            height: 64,
            child: GestureDetector(
              onTap: onTaskbarTap,
              behavior: HitTestBehavior.opaque,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xCC1A1A1A),
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Center(child: Text('taskbar')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _writeShot(WidgetTester tester, String filename) async {
  final artifacts = debugShotDirectory();
  if (artifacts == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('cw-card-shot')),
  );
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(
    '${artifacts.path}/$filename',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  testWidgets('tap opens continue-watching playback without leaving home', (
    tester,
  ) async {
    late _RecordingPlaybackLauncher recorder;
    final history = _historyItem();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackLauncherProvider.overrideWith((ref) {
            recorder = _RecordingPlaybackLauncher(ref);
            return recorder;
          }),
        ],
        child: _shell(child: ContinueWatchingCard(historyItem: history)),
      ),
    );

    await tester.tap(find.byType(ContinueWatchingCard));
    await tester.pump();

    expect(recorder.playCalls, 1);
    expect(recorder.played?.lastEpisodeUrl, 'abc|ep9');
    expect(find.text('عرض التفاصيل'), findsNothing);
    expect(find.text('taskbar'), findsOneWidget);
  });

  testWidgets(
    'long-press menu appears above the taskbar and keeps its actions',
    (tester) async {
      var taskbarTaps = 0;
      final continueWatching = _FakeContinueWatching();
      final history = _historyItem();
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(TestFonts.loadWalkthroughFonts);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            continueWatchingProvider.overrideWith(() => continueWatching),
          ],
          child: _shell(
            onTaskbarTap: () => taskbarTaps++,
            child: ContinueWatchingCard(historyItem: history),
          ),
        ),
      );

      await tester.longPress(find.byType(ContinueWatchingCard));
      await tester.pumpAndSettle();

      expect(find.text('عرض التفاصيل'), findsOneWidget);
      expect(find.text('إزالة من السجل'), findsOneWidget);
      expect(find.text('إلغاء'), findsOneWidget);
      await tester.runAsync(
        () => _writeShot(tester, 'cw_longpress_menu_above_nav.png'),
      );

      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();

      expect(find.text('إلغاء'), findsNothing);
      expect(taskbarTaps, 0);
    },
  );

  testWidgets('long-press remove still deletes the continue-watching item', (
    tester,
  ) async {
    late _FakeContinueWatching continueWatching;
    final history = _historyItem();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          continueWatchingProvider.overrideWith(() {
            continueWatching = _FakeContinueWatching();
            return continueWatching;
          }),
        ],
        child: _shell(child: ContinueWatchingCard(historyItem: history)),
      ),
    );

    await tester.longPress(find.byType(ContinueWatchingCard));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إزالة من السجل'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(continueWatching.removed, <String>[history.item.url]);
    expect(find.text('إزالة من السجل'), findsNothing);
  });
}

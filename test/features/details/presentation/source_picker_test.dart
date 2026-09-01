import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/source_picker.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';

const _shotKey = ValueKey('source-picker-shot');

Future<void> _writeShot(WidgetTester tester, String filename) async {
  final artifacts = Directory('/opt/cursor/artifacts');
  if (!artifacts.existsSync()) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shotKey),
  );
  final image = await boundary.toImage(pixelRatio: 2);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(
    '${artifacts.path}/$filename',
  ).writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  group('sourcePickerHeader', () {
    test(
      'uses the server episode label instead of a generic source prompt',
      () {
        expect(sourcePickerHeader('الحلقة 10', isArabic: true), 'الحلقة 10');
        expect(sourcePickerHeader('الفيلم', isArabic: true), 'الفيلم');
        expect(sourcePickerHeader('مترجم', isArabic: true), 'مترجم');
      },
    );

    test('keeps the localized generic prompt when no episode is available', () {
      expect(sourcePickerHeader(null, isArabic: true), 'اختر المصدر');
      expect(sourcePickerHeader('  ', isArabic: false), 'Choose source');
    });
  });

  group('episodePickerTitle', () {
    test('uses the primary server label, not the creative title', () {
      expect(
        episodePickerTitle(
          Episode(
            name: 'نهاية الرحلة',
            url: 'https://example.com/ep10',
            episode: 10,
            serverName: 'الحلقة 10',
          ),
        ),
        'الحلقة 10',
      );
      expect(
        episodePickerTitle(
          Episode(
            name: 'مدبلج',
            url: 'https://example.com/movie-dub',
            episode: 0,
            serverName: 'مدبلج',
          ),
        ),
        'مدبلج',
      );
    });

    test('returns null when there is no episode identity', () {
      expect(episodePickerTitle(null), isNull);
      expect(
        episodePickerTitle(
          Episode(name: '', url: 'https://example.com/unknown', episode: 0),
        ),
        isNull,
      );
    });
  });

  testWidgets('shows a loading state in the sheet until servers arrive', (
    tester,
  ) async {
    final pending = Completer<List<StreamResult>>();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
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
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  unawaited(
                    showStreamSourcePicker(
                      context,
                      const <StreamResult>[],
                      sourcesFuture: pending.future,
                      forDownload: false,
                      episodeLabel: 'حلقة 9',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('حلقة 9'), findsOneWidget);
    expect(find.byType(AppLoadingIndicator), findsOneWidget);
    expect(find.text('جارٍ التحميل...'), findsOneWidget);
    expect(find.text('جارٍ الحل...'), findsNothing);
    expect(find.text('PD'), findsNothing);
    await tester.runAsync(
      () => _writeShot(tester, 'cw_server_sheet_loading.png'),
    );

    pending.complete(<StreamResult>[
      const StreamResult(url: 'src-pd', source: 'PD', quality: '1080'),
      const StreamResult(url: 'src-mf', source: 'MF', quality: '720'),
    ]);
    await tester.pumpAndSettle();

    expect(find.byType(AppLoadingIndicator), findsNothing);
    expect(find.text('PD'), findsOneWidget);
    expect(find.text('MF'), findsOneWidget);
    await tester.runAsync(() => _writeShot(tester, 'cw_server_sheet_rows.png'));
  });

  testWidgets('download loading uses the same sheet and جارٍ التحميل', (
    tester,
  ) async {
    final pending = Completer<List<StreamResult>>();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
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
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  unawaited(
                    showStreamSourcePicker(
                      context,
                      const <StreamResult>[],
                      sourcesFuture: pending.future,
                      forDownload: true,
                      episodeLabel: 'الحلقة 9',
                    ),
                  );
                },
                child: const Text('download'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('download'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('الحلقة 9'), findsOneWidget);
    expect(find.byType(AppLoadingIndicator), findsOneWidget);
    expect(find.text('جارٍ التحميل...'), findsOneWidget);
    expect(find.text('جارٍ الحل...'), findsNothing);
    await tester.runAsync(
      () => _writeShot(tester, 'download_picker_sheet_loading.png'),
    );

    pending.complete(const <StreamResult>[
      StreamResult(url: 'src-pd', source: 'PD', quality: '1080'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('PD'), findsOneWidget);
    expect(find.byIcon(Icons.file_download_outlined), findsOneWidget);
  });

  testWidgets('server rows stay tappable above a floating taskbar', (
    tester,
  ) async {
    var taskbarTaps = 0;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
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
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () {
                      unawaited(
                        showStreamSourcePicker(
                          context,
                          const <StreamResult>[
                            StreamResult(
                              url: 'src-pd',
                              source: 'PD',
                              quality: '1080',
                            ),
                            StreamResult(
                              url: 'src-mf',
                              source: 'MF',
                              quality: '720',
                            ),
                          ],
                          forDownload: false,
                          episodeLabel: 'حلقة 9',
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
            bottomNavigationBar: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: SizedBox(
                height: 64,
                child: GestureDetector(
                  onTap: () => taskbarTaps++,
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
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('PD'), findsOneWidget);
    await tester.runAsync(
      () => _writeShot(tester, 'cw_server_sheet_above_nav.png'),
    );
    await tester.tap(find.text('PD'));
    await tester.pumpAndSettle();

    expect(find.text('PD'), findsNothing);
    expect(taskbarTaps, 0);
  });
}

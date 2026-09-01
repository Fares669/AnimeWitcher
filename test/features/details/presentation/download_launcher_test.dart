import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/features/details/presentation/download_launcher.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/loading_dialog.dart';
import 'package:animewitcher/shared/widgets/loading_indicator.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';

const _shotKey = ValueKey('download-server-loading');

class _StubExtensions extends ExtensionManager {
  _StubExtensions(this._providers);

  final List<AnimeWitcherProvider> _providers;

  @override
  List<AnimeWitcherProvider> build() => _providers;
}

class _FakeDownloadSource extends AnimeWitcherProvider {
  _FakeDownloadSource(this.sources);

  final Completer<List<StreamResult>> sources;

  @override
  String get packageName => 'fake.download';

  @override
  String get name => 'Fake';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    return const <String, List<MultimediaItem>>{};
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    return const <MultimediaItem>[];
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    return MultimediaItem(title: 'Details', url: url, posterUrl: '');
  }

  @override
  Future<List<StreamResult>> loadStreamSources(String url) {
    return sources.future;
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    return const <StreamResult>[];
  }
}

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
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('download opens the same server sheet loading as play', (
    tester,
  ) async {
    final pending = Completer<List<StreamResult>>();
    final source = _FakeDownloadSource(pending);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _StubExtensions(<AnimeWitcherProvider>[source]),
          ),
          activeProviderProvider.overrideWithValue(source),
        ],
        child: RepaintBoundary(
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
                builder: (context) {
                  return TextButton(
                    onPressed: () {
                      unawaited(
                        ProviderScope.containerOf(context)
                            .read(downloadLauncherProvider)
                            .launch(
                              context,
                              MultimediaItem(
                                title: 'Show',
                                url: 'https://example.test/show',
                                posterUrl: '',
                              ),
                              episode: Episode(
                                name: '',
                                url: 'https://example.test/ep9',
                                episode: 9,
                                serverName: 'الحلقة 9',
                              ),
                            ),
                      );
                    },
                    child: const Text('download'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('download'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(LoadingDialog), findsNothing);
    expect(find.text('جارٍ الحل...'), findsNothing);
    expect(find.byType(AppLoadingIndicator), findsOneWidget);
    expect(find.text('جارٍ التحميل...'), findsOneWidget);
    expect(find.text('الحلقة 9'), findsOneWidget);

    await tester.runAsync(
      () => _writeShot(tester, 'download_server_sheet_loading.png'),
    );

    pending.complete(const <StreamResult>[
      StreamResult(url: 'src-pd', source: 'PD', quality: '1080'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('جارٍ التحميل...'), findsNothing);
    expect(find.text('PD'), findsOneWidget);
    expect(find.byIcon(Icons.file_download_outlined), findsOneWidget);
  });
}

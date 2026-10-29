import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_screen.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/manga/reader/subsampling/src/subsampling_image_painter.dart';
import 'package:animewitcher/features/manga/reader/subsampling/ffi_image_decoder.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_continuous_zoom_surface.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_image_actions_sheet.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_settings_panel.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

final class _Provider extends AnimeWitcherProvider {
  @override
  String get packageName => 'test.reader.gestures';
  @override
  String get name => 'Gesture reader';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const <String>['en'];
  @override
  Set<ProviderType> get supportedTypes => const <ProviderType>{
    ProviderType.manga,
  };
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const [];
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

final class _Manager extends ExtensionManager {
  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[_Provider()];
}

final class _Storage extends StorageService {
  @override
  String? getString(String key) => null;
  @override
  Future<void> setString(String key, String? value) async {}
}

final class _Settings extends MangaReaderSettingsNotifier {
  _Settings(this.initial);
  final MangaReaderSettings initial;
  @override
  MangaReaderSettings build() => initial;
  @override
  Future<void> setSettings(MangaReaderSettings value) async => state = value;
}

final _fixtureDirectories = <Directory>[];

const _topBar = ValueKey<String>('manga-reader-top-bar');
const _bottomBar = ValueKey<String>('manga-reader-page-bar');

Future<ProviderContainer> _pumpReader(
  WidgetTester tester,
  MangaReaderMode mode, {
  bool usePageTapZones = true,
  int navigationLayout = 0,
  bool doublePage = false,
  bool showActionsOnLongTap = true,
  bool webtoonDoubleTapZoomEnabled = true,
  bool verticalBar = false,
}) async {
  // Real local static pages exercise the nested image, zoom, and scroll
  // recognizers. An empty-page screen would miss their gesture competition.
  final directory = Directory.systemTemp.createTempSync('aw_reader_gestures_');
  _fixtureDirectories.add(directory);
  await tester.runAsync(() async {
    // BMP is supported by the native decoder on every test platform.
    const width = 40;
    const height = 40;
    final data = Uint8List(54 + width * height * 4);
    final header = ByteData.sublistView(data)
      ..setUint8(0, 0x42)
      ..setUint8(1, 0x4d)
      ..setUint32(2, data.length, Endian.little)
      ..setUint32(10, 54, Endian.little)
      ..setUint32(14, 40, Endian.little)
      ..setInt32(18, width, Endian.little)
      ..setInt32(22, height, Endian.little)
      ..setUint16(26, 1, Endian.little)
      ..setUint16(28, 32, Endian.little)
      ..setUint32(34, width * height * 4, Endian.little);
    for (var offset = 54; offset < data.length; offset += 4) {
      header.setUint32(offset, 0xff326496, Endian.little);
    }
    for (var i = 0; i < 4; i++) {
      File('${directory.path}/${(i + 1).toString().padLeft(4, '0')}.bmp')
          .writeAsBytesSync(data);
    }
    await const MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'gesture-manga',
      chapterId: 'gesture-chapter',
      pageCount: 4,
      completedIndexes: {0, 1, 2, 3},
      isComplete: true,
    ).writeTo(directory);
  });
  final settings = MangaReaderSettings(
    defaultMode: mode,
    showReadingMode: false,
    keepScreenOn: false,
    fullScreen: false,
    usePageTapZones: usePageTapZones,
    navigationLayout: navigationLayout,
    personalDoublePage: <String, bool>{'gesture-manga': doublePage},
    showActionsOnLongTap: showActionsOnLongTap,
    webtoonDoubleTapZoomEnabled: webtoonDoubleTapZoomEnabled,
    verticalBarModes: verticalBar ? <MangaReaderMode>{mode} : const {},
  );
  const chapter = MangaChapter(
    id: 'gesture-chapter',
    mangaId: 'gesture-manga',
    url: 'https://example.test/chapter/1',
    name: 'Chapter 1',
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        extensionManagerProvider.overrideWith(_Manager.new),
        mangaReadingRepositoryProvider.overrideWithValue(
          MangaReadingRepository(_Storage()),
        ),
        mangaReaderSettingsProvider.overrideWith(() => _Settings(settings)),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MangaReaderScreen(
          manga: MultimediaItem(
            title: 'Gesture manga',
            url: 'https://example.test/manga',
            posterUrl: '',
            provider: 'test.reader.gestures',
            contentType: MultimediaContentType.manga,
          ),
          chapter: chapter,
          chapters: const [chapter],
          localChapterDirectory: directory.path,
        ),
      ),
    ),
  );
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (find.byType(SubsamplingImageRenderWidget).evaluate().isNotEmpty) break;
  }
  expect(find.byType(SubsamplingImageRenderWidget), findsWidgets);
  expect(find.text('إعادة المحاولة'), findsNothing);
  return ProviderScope.containerOf(
    tester.element(find.byType(MangaReaderScreen)),
  );
}

void _expectBars(
  WidgetTester tester, {
  required bool visible,
  bool vertical = false,
}) {
  final top = find.byKey(_topBar);
  final opacity = tester.widget<AnimatedOpacity>(
    find.ancestor(of: top, matching: find.byType(AnimatedOpacity)).first,
  );
  expect(opacity.opacity, visible ? 1 : 0);
  final bar = find.byKey(
    vertical
        ? const ValueKey<String>('manga-reader-page-bar-vertical')
        : _bottomBar,
  );
  final rect = tester.getRect(bar);
  final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
  expect(rect.overlaps(Offset.zero & viewport), visible);
}

Future<void> _settleTap(WidgetTester tester) async {
  // A single tap waits out the reader's double-tap zoom recognizer.
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 1000));
}

Finder get _slider =>
    find.descendant(of: find.byKey(_bottomBar), matching: find.byType(Slider));

double _page(WidgetTester tester) => tester.widget<Slider>(_slider).value;

double _zoom(WidgetTester tester, MangaReaderMode mode) {
  if (!mode.isContinuous) {
    return tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer).first)
        .transformationController!
        .value
        .getMaxScaleOnAxis();
  }
  final transform = find
      .descendant(
        of: find.byType(MangaContinuousZoomSurface),
        matching: find.byType(Transform),
      )
      .first;
  return tester.widget<Transform>(transform).transform.getMaxScaleOnAxis();
}

void main() {
  setUpAll(
    () => VisibilityDetectorController.instance.updateInterval = Duration.zero,
  );
  tearDownAll(() async {
    await ffiImageDecoder.stop();
    for (final directory in _fixtureDirectories) {
      directory.deleteSync(recursive: true);
    }
  });

  for (final mode in MangaReaderMode.values) {
    testWidgets(
      '${mode.name}: one tap hides both bars and one tap shows them',
      (tester) async {
        await _pumpReader(tester, mode);
        _expectBars(tester, visible: true);
        final center = tester.getCenter(find.byType(MangaReaderScreen));
        await tester.tapAt(center);
        await _settleTap(tester);
        _expectBars(tester, visible: false);
        expect(_page(tester), 0);
        await tester.tapAt(center);
        await _settleTap(tester);
        _expectBars(tester, visible: true);
        expect(_page(tester), 0);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '${mode.name}: tap while the page is moving does not show the bars',
      (tester) async {
        await _pumpReader(tester, mode);
        final center = tester.getCenter(find.byType(MangaReaderScreen));
        await tester.tapAt(center);
        await _settleTap(tester);
        _expectBars(tester, visible: false);
        // Start the page moving, then tap to catch it mid-motion: that tap
        // must not bring the bars back.
        final direction = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .axisDirection;
        final delta = switch (direction) {
          AxisDirection.down => const Offset(0, -500),
          AxisDirection.up => const Offset(0, 500),
          AxisDirection.right => const Offset(-650, 0),
          AxisDirection.left => const Offset(650, 0),
        };
        await tester.flingFrom(center, delta, 1000);
        await tester.tapAt(center);
        await _settleTap(tester);
        _expectBars(tester, visible: false);
        // Once the page has settled, a tap shows the bars again.
        await tester.tapAt(center);
        await _settleTap(tester);
        _expectBars(tester, visible: true);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '${mode.name}: long press cannot open image actions with saved preference enabled',
      (tester) async {
        await _pumpReader(tester, mode);
        await tester.longPressAt(
          tester.getCenter(find.byType(MangaReaderScreen)),
        );
        await _settleTap(tester);
        expect(find.byType(MangaReaderImageActionsSheet), findsNothing);
        _expectBars(tester, visible: true);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('${mode.name}: double tap zooms without toggling bars', (
      tester,
    ) async {
      await _pumpReader(tester, mode);
      final center = tester.getCenter(find.byType(MangaReaderScreen));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 60));
      _expectBars(tester, visible: true);
      await tester.tapAt(center);
      await _settleTap(tester);
      expect(_zoom(tester, mode), greaterThan(1));
      _expectBars(tester, visible: true);
      expect(_page(tester), 0);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 60));
      _expectBars(tester, visible: true);
      await tester.tapAt(center);
      await _settleTap(tester);
      expect(_zoom(tester, mode), closeTo(1, 0.001));
      _expectBars(tester, visible: true);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('${mode.name}: pinch zoom keeps the bars unchanged', (
      tester,
    ) async {
      await _pumpReader(tester, mode);
      final center = tester.getCenter(find.byType(MangaReaderScreen));
      final separation = mode.isVertical
          ? const Offset(50, 0)
          : const Offset(0, 50);
      final movement = mode.isVertical
          ? const Offset(30, 0)
          : const Offset(0, 30);
      final first = await tester.startGesture(center - separation, pointer: 1);
      final second = await tester.startGesture(center + separation, pointer: 2);
      await tester.pump(const Duration(milliseconds: 20));
      for (var i = 0; i < 3; i++) {
        await first.moveBy(-movement);
        await second.moveBy(movement);
        await tester.pump(const Duration(milliseconds: 20));
      }
      await first.up();
      await second.up();
      await _settleTap(tester);
      expect(_zoom(tester, mode), greaterThan(1));
      _expectBars(tester, visible: true);
      expect(_page(tester), 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('${mode.name}: swiping still navigates pages', (tester) async {
      await _pumpReader(tester, mode);
      final center = tester.getCenter(find.byType(MangaReaderScreen));
      // Follow the rendered scroll direction, including the app's RTL locale.
      final direction = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .axisDirection;
      final delta = switch (direction) {
        AxisDirection.down => const Offset(0, -500),
        AxisDirection.up => const Offset(0, 500),
        AxisDirection.right => const Offset(-650, 0),
        AxisDirection.left => const Offset(650, 0),
      };
      await tester.timedDragFrom(
        center,
        delta,
        const Duration(milliseconds: 600),
      );
      await _settleTap(tester);
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(_page(tester), greaterThan(0));
      expect(find.byType(MangaReaderImageActionsSheet), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('portrait phone toggles both floating bars with one tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpReader(tester, MangaReaderMode.webtoon);
    final center = tester.getCenter(find.byType(MangaReaderScreen));
    _expectBars(tester, visible: true);
    await tester.tapAt(center);
    await _settleTap(tester);
    _expectBars(tester, visible: false);
    await tester.tapAt(center);
    await _settleTap(tester);
    _expectBars(tester, visible: true);
    await tester.longPressAt(center);
    await _settleTap(tester);
    expect(find.byType(MangaReaderImageActionsSheet), findsNothing);
    _expectBars(tester, visible: true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('legacy false preference also absorbs long holds', (
    tester,
  ) async {
    await _pumpReader(
      tester,
      MangaReaderMode.webtoon,
      showActionsOnLongTap: false,
    );
    await tester.longPressAt(const Offset(400, 300));
    await _settleTap(tester);
    expect(find.byType(MangaReaderImageActionsSheet), findsNothing);
    _expectBars(tester, visible: true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'disabled continuous double-tap zoom does not toggle chrome twice',
    (tester) async {
      await _pumpReader(
        tester,
        MangaReaderMode.webtoon,
        webtoonDoubleTapZoomEnabled: false,
      );
      await tester.tapAt(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 60));
      _expectBars(tester, visible: true);
      await tester.tapAt(const Offset(400, 300));
      await _settleTap(tester);
      _expectBars(tester, visible: true);
      expect(_zoom(tester, MangaReaderMode.webtoon), 1);
      await tester.tapAt(const Offset(400, 300));
      await _settleTap(tester);
      _expectBars(tester, visible: false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final layout in <int>[1, 2, 3]) {
    testWidgets(
      'layout $layout preserves navigation and toggles in its menu zone',
      (tester) async {
        await _pumpReader(
          tester,
          MangaReaderMode.pagedLtr,
          navigationLayout: layout,
        );
        final menu = layout == 2
            ? const Offset(400, 100)
            : const Offset(400, 300);
        await tester.tapAt(menu);
        await _settleTap(tester);
        _expectBars(tester, visible: false);
        await tester.tapAt(menu);
        await _settleTap(tester);
        _expectBars(tester, visible: true);
        final next = layout == 1
            ? const Offset(760, 470)
            : const Offset(760, 300);
        await tester.tapAt(next);
        await _settleTap(tester);
        expect(_page(tester), 1);
        _expectBars(tester, visible: true);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('layout 4 keeps its center menu reachable and edge navigation', (
    tester,
  ) async {
    await _pumpReader(tester, MangaReaderMode.pagedLtr, navigationLayout: 4);
    await tester.tapAt(const Offset(420, 300));
    await _settleTap(tester);
    _expectBars(tester, visible: false);
    expect(_page(tester), 0);
    await tester.tapAt(const Offset(380, 300));
    await _settleTap(tester);
    _expectBars(tester, visible: true);
    expect(_page(tester), 0);
    await tester.tapAt(const Offset(760, 300));
    await _settleTap(tester);
    expect(_page(tester), 1);
    _expectBars(tester, visible: true);
    await tester.tapAt(const Offset(40, 300));
    await _settleTap(tester);
    expect(_page(tester), 0);
    _expectBars(tester, visible: true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final disabled in <bool>[false, true]) {
    testWidgets(
      'tap zones ${disabled ? 'disabled' : 'layout none'}: one tap toggles anywhere',
      (tester) async {
        await _pumpReader(
          tester,
          MangaReaderMode.pagedLtr,
          usePageTapZones: !disabled,
          navigationLayout: disabled ? 0 : 5,
        );
        await tester.tapAt(const Offset(40, 300));
        await _settleTap(tester);
        _expectBars(tester, visible: false);
        expect(_page(tester), 0);
        await tester.tapAt(const Offset(760, 300));
        await _settleTap(tester);
        _expectBars(tester, visible: true);
        expect(_page(tester), 0);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('configured edge tap turns a page without hiding the bars', (
    tester,
  ) async {
    await _pumpReader(tester, MangaReaderMode.pagedLtr);
    await tester.tapAt(const Offset(760, 300));
    await _settleTap(tester);
    expect(_page(tester), 1);
    _expectBars(tester, visible: true);
    await tester.tapAt(const Offset(40, 300));
    await _settleTap(tester);
    expect(_page(tester), 0);
    _expectBars(tester, visible: true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'reader controls keep their own taps and right-click still opens actions',
    (tester) async {
      final container = await _pumpReader(tester, MangaReaderMode.pagedLtr);
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-bar-crop')),
      );
      await _settleTap(tester);
      expect(container.read(mangaReaderSettingsProvider).cropBorders, isTrue);
      _expectBars(tester, visible: true);
      await tester.tap(_slider);
      await _settleTap(tester);
      expect(_page(tester), greaterThan(0));
      _expectBars(tester, visible: true);
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-settings-button')),
      );
      await _settleTap(tester);
      expect(find.byType(MangaReaderSettingsPanel), findsOneWidget);
      _expectBars(tester, visible: true);
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-panel-tab-general')),
      );
      await _settleTap(tester);
      expect(
        find.byKey(
          const ValueKey<String>('manga-reader-switch-long-tap-actions'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('manga-reader-switch-keep-on')),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(400, 100));
      await _settleTap(tester);
      expect(find.byType(MangaReaderSettingsPanel), findsNothing);
      _expectBars(tester, visible: true);
      final click = await tester.startGesture(
        const Offset(400, 250),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await click.up();
      await _settleTap(tester);
      expect(find.byType(MangaReaderImageActionsSheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('two-page spread and vertical page bar toggle with one tap', (
    tester,
  ) async {
    await _pumpReader(
      tester,
      MangaReaderMode.pagedLtr,
      doublePage: true,
      verticalBar: true,
    );
    _expectBars(tester, visible: true, vertical: true);
    await tester.tapAt(const Offset(400, 300));
    await _settleTap(tester);
    _expectBars(tester, visible: false, vertical: true);
    await tester.tapAt(const Offset(400, 300));
    await _settleTap(tester);
    _expectBars(tester, visible: true, vertical: true);
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(400, 300));
    await _settleTap(tester);
    expect(_zoom(tester, MangaReaderMode.pagedLtr), greaterThan(1));
    _expectBars(tester, visible: true, vertical: true);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_desktop_hero.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _CachePaths extends PathProviderPlatform {
  _CachePaths(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

Widget _hero(String? logoUrl) {
  final item = MultimediaItem(
    title: 'Fixture anime title',
    url: 'https://logo.fixture.invalid/watch/anime',
    posterUrl: '',
    logoUrl: logoUrl,
  );
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: DetailsDesktopHero(
          displayItem: item,
          details: item,
          detailsState: AsyncData<MultimediaItem?>(item),
          isMovie: false,
          itemUrl: item.url,
          onRefresh: () async {},
        ),
      ),
    ),
  );
}

void main() {
  late Directory root;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('aw_details_logo_test_');
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _CachePaths(root.path);
    try {
      await DefaultCacheManager().getFileFromCache('aw-details-logo-setup');
    } finally {
      PathProviderPlatform.instance = paths;
    }
  });
  tearDownAll(() => root.delete(recursive: true));

  for (final higherQuality in [true, false]) {
    testWidgets('hero decodes one display-height logo (HQ=$higherQuality)', (
      tester,
    ) async {
      final cache = PaintingBinding.instance.imageCache;
      cache
        ..clear()
        ..clearLiveImages();
      final previousQuality = highQualityArtwork.value;
      highQualityArtwork.value = higherQuality;
      tester.view.physicalSize = const Size(2560, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(() {
        cache
          ..clear()
          ..clearLiveImages();
        tester.view.reset();
        highQualityArtwork.value = previousQuality;
      });

      final url = 'https://logo.fixture.invalid/big-$higherQuality.png';
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
          ..drawColor(const Color(0xff28619d), ui.BlendMode.src)
          ..drawRect(
            const Rect.fromLTWH(1400, 0, 1400, 960),
            Paint()..color = const Color(0xffc94b36),
          );
        final picture = recorder.endRecording();
        final image = await picture.toImage(2800, 960);
        picture.dispose();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        image.dispose();
        await DefaultCacheManager().putFile(
          url,
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          fileExtension: 'png',
        );
      });

      const boundary = ValueKey<String>('details-logo-render');
      await tester.pumpWidget(
        RepaintBoundary(key: boundary, child: _hero(url)),
      );
      final logo = find.byWidgetPredicate(
        (widget) =>
            widget is RawImage && widget.height == 96 && widget.image != null,
      );
      for (
        var attempt = 0;
        attempt < 80 && logo.evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pump(const Duration(milliseconds: 1100));

      final raw = tester.widget<RawImage>(logo);
      final image = raw.image!;
      final rendered = tester.getSize(logo);
      final original = CachedNetworkImageProvider(url);
      final rawStatus = cache.statusForKey(original);
      final bytes = cache.currentSizeBytes;
      debugPrint(
        'Hero logo HQ=$higherQuality: draw ${rendered.width}x${rendered.height}, '
        'decode ${image.width}x${image.height}, cache=$bytes B, '
        'entries=${cache.currentSize}, original=${rawStatus.tracked}',
      );
      expect(rendered.height, 96);
      expect(rendered.width, closeTo(280, 0.5));
      final color = (await tester.runAsync(image.toByteData))!.getUint32(0);
      expect(color, 0x28619dff);
      final paintedBox = tester.getRect(logo);
      final render = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundary),
      );
      final paintedColors = await tester.runAsync(() async {
        final screenshot = await render.toImage();
        try {
          final rgba = (await screenshot.toByteData())!;
          final y = paintedBox.center.dy.floor();
          int at(double x) =>
              rgba.getUint32((y * screenshot.width + x.floor()) * 4);
          return (at(paintedBox.left + 20), at(paintedBox.right - 20));
        } finally {
          screenshot.dispose();
        }
      });
      expect(paintedColors, (0x28619dff, 0xc94b36ff));
      expect((image.width, image.height), (700, 240));
      expect(rawStatus.tracked, isFalse);
      expect(cache.currentSize, 1);
      expect(bytes, 700 * 240 * 4);
    });
  }

  testWidgets('a missing logo paints text without a network image', (
    tester,
  ) async {
    await tester.pumpWidget(_hero(''));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == 'Fixture anime title' &&
            widget.style?.fontWeight == FontWeight.bold,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is CachedNetworkImage && widget.imageUrl.isEmpty,
      ),
      findsNothing,
    );
  });
}

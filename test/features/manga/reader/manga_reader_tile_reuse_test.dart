import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/subsampling/src/subsampling_image_painter.dart';
import 'package:animewitcher/features/manga/reader/subsampling/subsampling_scale_image_view.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file/local.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as pixel;

const _capture = ValueKey<String>('tile-reuse-capture');
const _red = [212, 40, 56, 255];
const _green = [20, 166, 76, 255];

void main() {
  group('reader tile reuse', skip: !Platform.isLinux, () {
    late Directory temp;
    setUp(() {
      temp = Directory.systemTemp.createTempSync('aw_reader_tile_reuse_');
    });
    tearDown(() async {
      await ffiImageDecoder.stop();
      temp.deleteSync(recursive: true);
    });

    testWidgets('paged image keeps its decoded tile across resize and fit', (
      tester,
    ) async {
      final file = _source(temp, 2100, 1400);
      final page = MangaPage(index: 0, imageUrl: file.uri.toString());
      Size? nativeSize;
      Widget pageAt(Size viewport, {bool fillWidth = false}) => _scene(
        viewport,
        MangaPageImage(
          page: page,
          expand: true,
          settings: MangaReaderSettings(
            dualPageRotateToFit: true,
            scaleType: fillWidth
                ? MangaReaderScaleType.fitWidth
                : MangaReaderScaleType.fitScreen,
          ),
          onImageSize: (value) => nativeSize = value,
        ),
      );

      await tester.pumpWidget(pageAt(const Size(180, 180)));
      await _settleTiles(tester, 1);
      expect(nativeSize, const Size(2100, 1400));
      expect(_renderer(tester).rotation, 90);
      final first = _tiles(tester).single;
      _expectPixel(await _shot(tester), 90, 45, _red);
      _expectPixel(await _shot(tester), 90, 135, _green);

      await tester.pumpWidget(pageAt(const Size(240, 200)));
      await tester.pump(const Duration(milliseconds: 160));
      await _settleTiles(tester, 1);
      expect(_tiles(tester).single, same(first));
      expect(_renderer(tester).scale, closeTo(200 / 2100, 1e-8));
      _expectPixel(await _shot(tester), 120, 50, _red);
      _expectPixel(await _shot(tester), 120, 150, _green);

      await tester.pumpWidget(pageAt(const Size(240, 200), fillWidth: true));
      await _settleTiles(tester, 1);
      expect(_tiles(tester).single, same(first));
      expect(_renderer(tester).scale, closeTo(240 / 1400, 1e-8));
      final fit = await _shot(tester);
      _expectPixel(fit, 120, 50, _red);
      _expectPixel(fit, 120, 150, _green);
    });

    testWidgets('same cropped selection keeps pixels through rotation/reset', (
      tester,
    ) async {
      final file = _source(temp, 110, 80, border: 5);
      final controller = SubsamplingScaleImageViewController();
      addTearDown(controller.dispose);
      Widget pageAt(int rotation, Rect region) => _scene(
        const Size(180, 180),
        SubsamplingScaleImageView(
          image: FileImage(file),
          resolvedFilePath: file.path,
          rotation: rotation,
          cropBorders: true,
          srcRect: region,
          controller: controller,
        ),
      );
      const source = Rect.fromLTWH(25, 0, 50, 70);

      await tester.pumpWidget(pageAt(0, source));
      await _settleTiles(tester, 1);
      final first = _tiles(tester).single;
      for (final angle in [0, 90, 180, 270]) {
        await tester.pumpWidget(pageAt(angle, source));
        await _settleTiles(tester, 1);
        expect(_tiles(tester).single, same(first));
        final shot = await _shot(tester);
        final swapped = angle == 90 || angle == 270;
        final reversed = angle == 180 || angle == 270;
        _expectPixel(
          shot,
          swapped ? 90 : 65,
          swapped ? 65 : 90,
          reversed ? _green : _red,
        );
        _expectPixel(
          shot,
          swapped ? 90 : 115,
          swapped ? 115 : 90,
          reversed ? _red : _green,
        );
      }

      controller.setScaleAndCenter(
        controller.minScale * 2,
        const Offset(25, 35),
      );
      await tester.pump();
      expect(_tiles(tester).single, same(first));
      controller.resetScaleAndCenter();
      await _settleTiles(tester, 1);
      expect(_tiles(tester).single, same(first));

      // Changing the actual source region is not a transform-only update.
      await tester.pumpWidget(pageAt(0, const Rect.fromLTWH(50, 0, 40, 70)));
      await _settleTiles(tester, 1);
      final replacement = _tiles(tester).single;
      expect(replacement, isNot(same(first)));
      expect(replacement.width, 40);
      expect(replacement.height, 70);
      _expectPixel(await _shot(tester), 90, 90, _green);
    });

    testWidgets('resize waits for the replacement file dimensions', (
      tester,
    ) async {
      final original = _source(temp, 110, 80);
      final replacement = _source(temp, 300, 180, name: 'replacement.png');
      final cache = _BlockedFileCache();
      final url = 'https://fixture.invalid/${temp.path.split('/').last}.png';
      final nextProvider = CachedNetworkImageProvider(url, cacheManager: cache);
      Size? ready;
      Widget pageAt(Size viewport, ImageProvider<Object> provider) => _scene(
        viewport,
        SubsamplingScaleImageView(
          image: provider,
          onImageLoaded: (width, height) {
            ready = Size(width.toDouble(), height.toDouble());
          },
        ),
      );

      await tester.pumpWidget(
        pageAt(const Size(180, 180), FileImage(original)),
      );
      await _settleTiles(tester, 1);
      expect(ready, const Size(110, 80));

      ready = null;
      await tester.pumpWidget(pageAt(const Size(240, 180), nextProvider));
      expect(cache.lookups, 1);
      await tester.pump(const Duration(milliseconds: 200));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(ready, isNull, reason: 'A resize must not decode the old file');
      expect(find.byType(SubsamplingImageRenderWidget), findsNothing);

      cache.response.complete(
        FileInfo(
          const LocalFileSystem().file(replacement.path),
          FileSource.Cache,
          DateTime(2030),
          url,
        ),
      );
      await _settleTiles(tester, 1);
      expect(ready, const Size(300, 180));
      expect(_tiles(tester).single.width, 300);
      final shot = await _shot(tester);
      _expectPixel(shot, 60, 90, _red);
      _expectPixel(shot, 180, 90, _green);
    });

    testWidgets('continuous tall page still paints the later tile', (
      tester,
    ) async {
      final file = _source(temp, 720, 4600, horizontal: true);
      final page = MangaPage(index: 0, imageUrl: file.uri.toString());
      // Both real decoder tiles (y=0..4096 and y=4096..4600) are in view.
      await tester.pumpWidget(
        _scene(const Size(90, 575), MangaPageImage(page: page)),
      );
      await _settleTiles(tester, 2);
      final before = _tiles(tester);
      final shot = await _shot(tester);
      _expectPixel(shot, 45, 100, _red);
      _expectPixel(shot, 45, 550, _green);
      await tester.pumpWidget(
        _scene(const Size(80, 560), MangaPageImage(page: page)),
      );
      await tester.pump(const Duration(milliseconds: 160));
      await _settleTiles(tester, 2);
      final after = _tiles(tester);
      expect(after[0], same(before[0]));
      expect(after[1], same(before[1]));
      final resized = await _shot(tester);
      _expectPixel(resized, 40, 100, _red);
      _expectPixel(resized, 40, 514, _green);
    });
  });
}

Widget _scene(Size size, Widget page) => MaterialApp(
  home: Scaffold(
    backgroundColor: Colors.black,
    body: Center(
      child: RepaintBoundary(
        key: _capture,
        child: SizedBox.fromSize(size: size, child: page),
      ),
    ),
  ),
);

File _source(
  Directory temp,
  int width,
  int height, {
  int border = 0,
  bool horizontal = false,
  String name = 'fixture.png',
}) {
  final img = pixel.Image(width: width, height: height);
  if (border > 0) pixel.fill(img, color: pixel.ColorRgb8(255, 255, 255));
  for (final (first, color) in [(true, _red), (false, _green)]) {
    pixel.fillRect(
      img,
      x1: !horizontal && !first ? width ~/ 2 : border,
      y1: horizontal && !first ? height ~/ 2 : border,
      x2: !horizontal && first ? width ~/ 2 - 1 : width - border - 1,
      y2: horizontal && first ? height ~/ 2 - 1 : height - border - 1,
      color: pixel.ColorRgb8(color[0], color[1], color[2]),
    );
  }
  return File('${temp.path}/$name')
    ..writeAsBytesSync(pixel.encodePng(img, level: 1));
}

RenderSubsamplingImage _renderer(WidgetTester tester) =>
    tester.renderObject<RenderSubsamplingImage>(
      find.byType(SubsamplingImageRenderWidget),
    );

List<ui.Image> _tiles(WidgetTester tester) => [
  for (final grid in _renderer(tester).tilingEngine.tileMap.values)
    for (final tile in grid)
      if (tile.image case final ui.Image image) image,
];

Future<void> _settleTiles(WidgetTester tester, int expected) async {
  for (var i = 0; i < 80; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(SubsamplingImageRenderWidget).evaluate().isNotEmpty &&
        _tiles(tester).length == expected) {
      // Settle the post-layout auto-rotation and any already requested pixels.
      for (var j = 0; j < 4; j++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 8)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (_tiles(tester).length == expected) return;
    }
  }
  fail('Reader did not finish loading its tiles');
}

Future<(int, ByteData)> _shot(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  final result = await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      return (
        image.width,
        (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
      );
    } finally {
      image.dispose();
    }
  });
  return result!;
}

void _expectPixel((int, ByteData) shot, int x, int y, List<int> rgba) {
  final (width, pixels) = shot;
  final offset = (y * width + x) * 4;
  expect(
    List<int>.generate(4, (channel) => pixels.getUint8(offset + channel)),
    rgba,
  );
}

class _BlockedFileCache extends Fake implements BaseCacheManager {
  final response = Completer<FileInfo?>();
  int lookups = 0;

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) {
    lookups++;
    return response.future;
  }
}

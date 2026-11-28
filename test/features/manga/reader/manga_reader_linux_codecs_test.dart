import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/subsampling/subsampling_scale_image_view.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_zoomable_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as pixel;

void main() {
  group('Linux system image codecs', skip: !Platform.isLinux, () {
    late Directory temp;
    setUp(() {
      temp = Directory.systemTemp.createTempSync('aw_linux_manga_codecs_');
    });
    tearDown(() async {
      await ffiImageDecoder.stop();
      temp.deleteSync(recursive: true);
    });

    testWidgets('local JPEG in the paged reader paints both halves', (
      tester,
    ) async {
      final file = File('${temp.path}/page.jpg')
        ..writeAsBytesSync(pixel.encodeJpg(_spread(), quality: 100));
      const key = ValueKey<String>('capture');
      Size? imageSize;
      await tester.pumpWidget(
        _scene(
          key,
          MangaPageImage(
            page: MangaPage(index: 0, imageUrl: file.uri.toString()),
            expand: true,
            onImageSize: (value) => imageSize = value,
          ),
        ),
      );
      await _waitFor(tester, () => imageSize != null);
      expect(imageSize, const Size(39, 32));
      final shot = await _screenshot(tester, key);
      _expectColor(shot, 46, 90, [212, 40, 56], tolerance: 5);
      _expectColor(shot, 134, 90, [20, 166, 76], tolerance: 5);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('continuous PNG supports cropped and split pages', (
      tester,
    ) async {
      final file = File('${temp.path}/spread.png')
        ..writeAsBytesSync(pixel.encodePng(_spread()));
      const key = ValueKey<String>('capture');
      final page = MangaPage(index: 0, imageUrl: file.uri.toString());
      Size? imageSize;
      Widget scene({Rect? source}) => _scene(
        key,
        MangaPageImage(
          key: ValueKey<Rect?>(source),
          page: page,
          sourceRect: source,
          settings: const MangaReaderSettings(cropBorders: true),
          onImageSize: (value) => imageSize = value,
        ),
      );

      await tester.pumpWidget(scene());
      await _waitFor(tester, () => imageSize != null);
      // Trim the 4 white pixels on each edge.
      expect(imageSize, const Size(31, 24));
      _expectColor(await _screenshot(tester, key), 125, 90, [20, 166, 76]);

      imageSize = null;
      await tester.pumpWidget(
        scene(source: const Rect.fromLTWH(15, 0, 16, 24)),
      );
      await _waitFor(tester, () => imageSize != null);
      expect(imageSize, const Size(16, 24));
      final shot = await _screenshot(tester, key);
      _expectColor(shot, 75, 90, [20, 166, 76]);
      _expectColor(shot, 110, 90, [20, 166, 76]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    for (final format in ['jpg', 'bmp']) {
      testWidgets(
        'wide $format keeps pixels through rotation and reader zoom',
        (tester) async {
          final spread = _spread();
          final file = File('${temp.path}/rotated.$format')
            ..writeAsBytesSync(
              format == 'jpg'
                  ? pixel.encodeJpg(spread, quality: 100)
                  : _rgbaBmp(spread),
            );
          const key = ValueKey<String>('capture');
          final controller = TransformationController();
          addTearDown(controller.dispose);
          bool loaded = false;
          await tester.pumpWidget(
            _scene(
              key,
              MangaZoomablePage(
                transformationController: controller,
                child: MangaPageImage(
                  page: MangaPage(index: 0, imageUrl: file.uri.toString()),
                  expand: true,
                  settings: const MangaReaderSettings(
                    dualPageRotateToFit: true,
                  ),
                  onImageSize: (_) => loaded = true,
                ),
              ),
            ),
          );
          await _waitFor(tester, () => loaded);
          final page = find.byType(SubsamplingScaleImageView);
          expect(tester.widget<SubsamplingScaleImageView>(page).rotation, 90);
          final before = await _screenshot(tester, key);
          _expectColor(before, 90, 46, [212, 40, 56], tolerance: 5);
          _expectColor(before, 90, 134, [20, 166, 76], tolerance: 5);

          final center = tester.getCenter(page);
          await tester.tapAt(center);
          await tester.pump(const Duration(milliseconds: 70));
          await tester.tapAt(center);
          await tester.pumpAndSettle();
          expect(controller.value.getMaxScaleOnAxis(), closeTo(2.5, 0.01));
          final after = await _screenshot(tester, key);
          _expectColor(after, 90, 46, [212, 40, 56], tolerance: 5);
          _expectColor(after, 90, 134, [20, 166, 76], tolerance: 5);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        },
      );
    }

    testWidgets('rotations preserve pixels of the cropped source rectangle', (
      tester,
    ) async {
      final file = File('${temp.path}/rotated-split.png')
        ..writeAsBytesSync(pixel.encodePng(_spread()));
      const key = ValueKey<String>('capture');
      const red = [212, 40, 56];
      const green = [20, 166, 76];
      for (final angle in [0, 90, 180, 270]) {
        var loaded = false;
        await tester.pumpWidget(
          _scene(
            key,
            SubsamplingScaleImageView(
              key: ValueKey<int>(angle),
              image: FileImage(file),
              cropBorders: true,
              srcRect: const Rect.fromLTWH(8, 0, 14, 24),
              rotation: angle,
              onReady: () => loaded = true,
            ),
          ),
        );
        await _waitFor(tester, () => loaded);
        final shot = await _screenshot(tester, key);
        final swapsAxes = angle == 90 || angle == 270;
        final reversed = angle == 180 || angle == 270;
        _expectColor(
          shot,
          swapsAxes ? 90 : 60,
          swapsAxes ? 60 : 90,
          reversed ? green : red,
        );
        _expectColor(
          shot,
          swapsAxes ? 90 : 120,
          swapsAxes ? 120 : 90,
          reversed ? red : green,
        );
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test(
      'PNG transforms correctly for subsampled tile output, including alpha',
      () async {
        final source = pixel.Image(width: 9, height: 11, numChannels: 4);
        pixel.fill(source, color: pixel.ColorRgba8(200, 100, 50, 128));
        source.setPixelRgba(3, 1, 18, 60, 160, 255);
        final file = File('${temp.path}/alpha.png')
          ..writeAsBytesSync(pixel.encodePng(source));
        expect(await ffiImageDecoder.getImageDimensionsAsync(file.path), [
          9,
          11,
        ]);
        final result = await ffiImageDecoder.decodeRegionAsync(
          DecodeParams(
            filePath: file.path,
            left: 1,
            top: 1,
            right: 9,
            bottom: 11,
            sampleSize: 2,
          ),
        );
        expect(result?.pointerAddress, isNotNull, reason: result?.error);
        final buffer = Pointer<Uint8>.fromAddress(result!.pointerAddress!);
        try {
          final rgba = buffer.asTypedList(4 * 5 * 4);
          // Renderer expects premultiplied alpha in the tile's RGBA buffer.
          expect(rgba.sublist(0, 8), [100, 50, 25, 128, 18, 60, 160, 255]);
          expect(rgba.sublist(rgba.length - 4), [100, 50, 25, 128]);
        } finally {
          result.dispose();
        }
      },
    );

    testWidgets(
      'corrupt JPEG reaches retry UI, then valid replacement paints',
      (tester) async {
        final file = File('${temp.path}/corrupt.jpg')
          ..writeAsBytesSync([255, 216, 255, 224, 0, 16]);
        const key = ValueKey<String>('capture');
        Size? imageSize;
        await tester.pumpWidget(
          _scene(
            key,
            MangaPageImage(
              page: MangaPage(index: 0, imageUrl: file.uri.toString()),
              expand: true,
              onImageSize: (value) => imageSize = value,
            ),
          ),
        );
        final retry = find.text('إعادة المحاولة');
        await _waitFor(tester, () => retry.evaluate().isNotEmpty);
        expect(imageSize, isNull);
        file.writeAsBytesSync(pixel.encodeJpg(_spread(), quality: 100));
        await tester.tap(retry);
        await _waitFor(tester, () => imageSize != null);
        expect(imageSize, const Size(39, 32));
        _expectColor(await _screenshot(tester, key), 46, 90, [
          212,
          40,
          56,
        ], tolerance: 5);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  });
}

pixel.Image _spread() {
  // Odd width also exercises three-channel row padding.
  final img = pixel.Image(width: 39, height: 32);
  pixel.fill(img, color: pixel.ColorRgb8(255, 255, 255));
  pixel.fillRect(
    img,
    x1: 4,
    y1: 4,
    x2: 18,
    y2: 27,
    color: pixel.ColorRgb8(212, 40, 56),
  );
  pixel.fillRect(
    img,
    x1: 19,
    y1: 4,
    x2: 34,
    y2: 27,
    color: pixel.ColorRgb8(20, 166, 76),
  );
  return img;
}

Uint8List _rgbaBmp(pixel.Image image) {
  const headerSize = 54;
  final bytes = ByteData(headerSize + image.width * image.height * 4);
  const le = Endian.little;
  bytes
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4d)
    ..setUint32(2, bytes.lengthInBytes, le)
    ..setUint32(10, headerSize, le)
    ..setUint32(14, 40, le)
    ..setInt32(18, image.width, le)
    ..setInt32(22, -image.height, le) // Top-down BGRA rows.
    ..setUint16(26, 1, le)
    ..setUint16(28, 32, le);
  var offset = headerSize;
  for (final px in image) {
    bytes
      ..setUint8(offset++, px.b.toInt())
      ..setUint8(offset++, px.g.toInt())
      ..setUint8(offset++, px.r.toInt())
      ..setUint8(offset++, 255);
  }
  return bytes.buffer.asUint8List();
}

Widget _scene(Key key, Widget page) => MaterialApp(
  home: Scaffold(
    backgroundColor: Colors.black,
    body: Center(
      child: RepaintBoundary(
        key: key,
        child: SizedBox(width: 180, height: 180, child: page),
      ),
    ),
  ),
);

Future<void> _waitFor(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (done()) {
      // Geometry changes after the first tile can schedule a new worker
      // request. Give its result a chance to paint after the settled state.
      for (var frame = 0; frame < 3; frame++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      return;
    }
  }
  fail('Reader did not reach the intended load state');
}

Future<ByteData> _screenshot(WidgetTester tester, Key key) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final data = await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      image.dispose();
    }
  });
  return data!;
}

void _expectColor(
  ByteData screenshot,
  int x,
  int y,
  List<int> rgb, {
  int tolerance = 0,
}) {
  final offset = (y * 180 + x) * 4;
  for (var i = 0; i < rgb.length; i++) {
    expect(screenshot.getUint8(offset + i), closeTo(rgb[i], tolerance));
  }
  expect(screenshot.getUint8(offset + 3), 255);
}

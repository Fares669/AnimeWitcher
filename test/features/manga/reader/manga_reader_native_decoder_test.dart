import 'dart:io';

import 'package:animewitcher/features/manga/reader/subsampling/ffi_image_decoder.dart';
import 'package:animewitcher/features/manga/reader/subsampling/subsampling_scale_image_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Mangayomi native decoder reads BMP dimensions', () async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_decoder_');
    addTearDown(() async {
      await ffiImageDecoder.stop();
      await temp.delete(recursive: true);
    });
    final file = File('${temp.path}/two_by_one.bmp');
    await file.writeAsBytes(_bmp2x1());

    final dimensions = await ffiImageDecoder.getImageDimensionsAsync(file.path);

    expect(dimensions, <int>[2, 1]);
  });

  test('last renderer releases native contexts after pending work', () async {
    final temp = await Directory.systemTemp.createTemp('aw_decoder_idle_');
    final decoder = FfiImageDecoder();
    final release = decoder.retainRenderer();
    addTearDown(() async {
      release();
      await decoder.stop();
      await temp.delete(recursive: true);
    });

    final file = File('${temp.path}/page.bmp');
    await file.writeAsBytes(_bmp2x1());
    // Closing before the initial request is dispatched must also clean up
    // the context that the worker opens later.
    final pending = decoder.getImageDimensionsAsync(file.path);
    release();
    expect(await pending, <int>[2, 1]);

    expect(await decoder.debugNativeCacheEntryCount(), 0);

    // The worker remains reusable without interrupting later chapter opens.
    final reopened = decoder.retainRenderer();
    addTearDown(reopened);
    expect(await decoder.getImageDimensionsAsync(file.path), <int>[2, 1]);
    expect(await decoder.debugNativeCacheEntryCount(), 1);
    reopened();
    await Future<void>.value();
    expect(await decoder.debugNativeCacheEntryCount(), 0);
  });

  test(
    'still-mounted or same-frame replacement keeps native contexts',
    () async {
      final temp = await Directory.systemTemp.createTemp('aw_decoder_active_');
      final decoder = FfiImageDecoder();
      final releaseFirst = decoder.retainRenderer();
      final releaseSecond = decoder.retainRenderer();
      addTearDown(() async {
        releaseFirst();
        releaseSecond();
        await decoder.stop();
        await temp.delete(recursive: true);
      });

      final file = File('${temp.path}/page.bmp');
      await file.writeAsBytes(_bmp2x1());
      expect(await decoder.getImageDimensionsAsync(file.path), <int>[2, 1]);

      releaseFirst();
      releaseFirst(); // idempotent
      expect(await decoder.debugNativeCacheEntryCount(), 1);

      releaseSecond();
      final replacement = decoder.retainRenderer();
      addTearDown(replacement);
      expect(await decoder.debugNativeCacheEntryCount(), 1);
      replacement();
      await Future<void>.value();
      expect(await decoder.debugNativeCacheEntryCount(), 0);
    },
  );

  testWidgets('popping the tiled page drops the native decoder cache', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('aw_decoder_pop_');
    final file = File('${temp.path}/page.bmp')..writeAsBytesSync(_bmp2x1());
    addTearDown(() async {
      await ffiImageDecoder.stop();
      await temp.delete(recursive: true);
    });
    var loaded = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SubsamplingScaleImageView(
                    image: FileImage(file),
                    resolvedFilePath: file.path,
                    onReady: () => loaded = true,
                  ),
                ),
              );
            },
            child: const Text('Read'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Read'));
    for (var attempt = 0; attempt < 30 && !loaded; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    expect(loaded, isTrue);
    expect(
      await tester.runAsync(ffiImageDecoder.debugNativeCacheEntryCount),
      1,
    );

    Navigator.of(tester.element(find.byType(SubsamplingScaleImageView))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Read'), findsOneWidget);
    expect(
      await tester.runAsync(ffiImageDecoder.debugNativeCacheEntryCount),
      0,
    );
  });
}

List<int> _bmp2x1() {
  // 32-bit BMP, matching Mangayomi's native regional BMP decoder.
  const fileSize = 62;
  const pixelOffset = 54;
  return <int>[
    0x42, 0x4d,
    fileSize, 0, 0, 0,
    0, 0, 0, 0,
    pixelOffset, 0, 0, 0,
    40, 0, 0, 0,
    2, 0, 0, 0,
    1, 0, 0, 0,
    1, 0,
    32, 0,
    0, 0, 0, 0,
    8, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    // BGRA pixels.
    0, 0, 255, 255,
    0, 255, 0, 255,
  ];
}

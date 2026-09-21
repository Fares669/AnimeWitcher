import 'dart:io';

import 'package:animewitcher/features/manga/reader/subsampling/ffi_image_decoder.dart';
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
}

List<int> _bmp2x1() {
  // 24-bit BMP, two pixels wide, one row padded to four-byte alignment.
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
    24, 0,
    0, 0, 0, 0,
    8, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    // BGR pixels + 2-byte row padding.
    0, 0, 255,
    0, 255, 0,
    0, 0,
  ];
}

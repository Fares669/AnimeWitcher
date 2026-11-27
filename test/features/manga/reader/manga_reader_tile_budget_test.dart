import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/features/manga/reader/subsampling/ffi_image_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'a large tile holds its staging budget until consumed or discarded',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('aw_tile_budget_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final source = _bmp(temp);
      final decoder = FfiImageDecoder.withTileBudget(24);
      addTearDown(decoder.stop);

      const bytes = 4 * 4 * 4;
      DecodeParams params({int sample = 1}) => DecodeParams(
        filePath: source,
        left: 0,
        top: 0,
        right: 4,
        bottom: 4,
        sampleSize: sample,
      );

      await tester.runAsync(() async {
        final first = (await decoder.decodeRegionAsync(params()))!;
        expect(first.pointerAddress, isNotNull, reason: first.error);
        expect(decoder.debugReservedTileBytes, bytes);
        try {
          final token = Object();
          final canceled = decoder.decodeRegionAsync(
            params(),
            cancelToken: token,
          );
          var delivered = false;
          final next = decoder.decodeRegionAsync(params()).then((result) {
            delivered = true;
            return result;
          });
          // Zero-pixel metadata requests can still complete while even a
          // single oversized tile owns the staging budget.
          expect(await decoder.getImageDimensionsAsync(source), [4, 4]);
          expect(delivered, isFalse);
          decoder.cancel(token);
          expect((await canceled)?.error, 'Cancelled');
          expect(decoder.debugReservedTileBytes, bytes);
          expect(
            (await decoder.decodeRegionAsync(params(sample: 0)))?.error,
            'Invalid tile size',
          );

          first.dispose();
          first.dispose();
          final second = (await next)!;
          expect(second.pointerAddress, isNotNull, reason: second.error);
          expect(decoder.debugReservedTileBytes, bytes);
          try {
            final image = await second.consumeImage();
            addTearDown(image.dispose);
            expect((image.width, image.height), (4, 4));
            expect(second.pointerAddress, isNull);
            expect(decoder.debugReservedTileBytes, 0);
          } finally {
            second.dispose();
          }
        } finally {
          first.dispose();
        }
      });
    },
    skip: !Platform.isLinux,
  );

  testWidgets('an unsuccessful decode returns its staging budget', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('aw_tile_budget_error_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final decoder = FfiImageDecoder.withTileBudget(24);
    addTearDown(decoder.stop);
    DecodeParams params(String filePath) => DecodeParams(
      filePath: filePath,
      left: 0,
      top: 0,
      right: 4,
      bottom: 4,
      sampleSize: 1,
    );
    await tester.runAsync(() async {
      final missing = await decoder.decodeRegionAsync(
        params('${temp.path}/missing.bmp'),
      );
      expect(missing?.error, contains('initialize decoder'));
      expect(decoder.debugReservedTileBytes, 0);
      final next = (await decoder.decodeRegionAsync(params(_bmp(temp))))!;
      expect(next.pointerAddress, isNotNull, reason: next.error);
      next.dispose();
      expect(decoder.debugReservedTileBytes, 0);
    });
  }, skip: !Platform.isLinux);
}

String _bmp(Directory dir) {
  const pixels = 4 * 4 * 4;
  final data = Uint8List(54 + pixels);
  final header = ByteData.sublistView(data)
    ..setUint16(0, 0x4d42, Endian.little)
    ..setUint32(2, data.length, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, 4, Endian.little)
    ..setInt32(22, -4, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little);
  // Uniform premultiplied BGRA fixture pixel.
  for (var offset = 54; offset < data.length; offset += 4) {
    header.setUint32(offset, 0xff82643a, Endian.little);
  }
  final file = File('${dir.path}/tile.bmp')..writeAsBytesSync(data);
  return file.path;
}

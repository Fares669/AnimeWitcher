import 'dart:async';
import 'dart:ui' as ui;

import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  test(
    'uses DPR and stable buckets without touching large or unbounded art',
    () {
      int? width(double logical, double dpr, {bool optimize = true}) =>
          artworkDisplayDecodeWidth(
            paintedWidth: logical,
            devicePixelRatio: dpr,
            highQuality: true,
            sizeHighQualityToDisplay: optimize,
          );
      expect(width(130, 3), 512);
      expect(width(131, 3), 512);
      expect(width(390, 3), 1472);
      expect(width(960, 2), isNull);
      expect(width(390, 3, optimize: false), isNull);
      expect(width(double.infinity, 2), isNull);
      expect(width(0, 2), isNull);
    },
  );

  test(
    'avoids cache-key churn for nearby actual rail widths in standard mode',
    () {
      int? width(double logical) => artworkDisplayDecodeWidth(
        paintedWidth: logical,
        devicePixelRatio: 2,
        highQuality: false,
        bucketStandardDecode: true,
      );
      expect(width(272), 544);
      expect(width(271), 544);
      expect(width(140), 288);
      expect(width(1400), 2048);
    },
  );

  testWidgets(
    'native display decode preserves source ratio and never upscales',
    (tester) async {
      Future<ui.Size> decodedSize(ui.Size size, int width) async {
        final jpeg = image.encodeJpg(
          image.Image(width: size.width.toInt(), height: size.height.toInt()),
        );
        final provider = ResizeImage(MemoryImage(jpeg), width: width);
        final stream = provider.resolve(ImageConfiguration.empty);
        final result = Completer<ui.Size>();
        final listener = ImageStreamListener((info, _) {
          final decoded = info.image;
          result.complete(
            ui.Size(decoded.width.toDouble(), decoded.height.toDouble()),
          );
          info.dispose();
        }, onError: (error, stack) => result.completeError(error, stack));
        stream.addListener(listener);
        try {
          return await result.future;
        } finally {
          stream.removeListener(listener);
        }
      }

      final target = artworkDisplayDecodeWidth(
        paintedWidth: 130,
        devicePixelRatio: 3,
        highQuality: true,
        sizeHighQualityToDisplay: true,
      )!;
      await tester.runAsync(() async {
        expect(
          await decodedSize(const ui.Size(1200, 1800), target),
          const ui.Size(512, 768),
        );
        expect(
          await decodedSize(const ui.Size(1920, 1080), target),
          const ui.Size(512, 288),
        );
        expect(
          await decodedSize(const ui.Size(480, 720), target),
          const ui.Size(480, 720),
        );
      });
    },
  );
}

import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets('paused local GIF keeps first pixels without a size listener', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('manga-gif-ticker-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/page.gif');
    final original = img.fill(
      img.Image(width: 12, height: 20, frameDuration: 80),
      color: img.ColorRgb8(197, 23, 73),
    );
    original.addFrame(
      img.fill(
        img.Image(width: 12, height: 20, frameDuration: 80),
        color: img.ColorRgb8(18, 171, 210),
      ),
    );
    file.writeAsBytesSync(img.encodeGif(original));
    final sizes = <Size>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: false,
          child: MangaPageImage(
            page: MangaPage(index: 0, imageUrl: file.uri.toString()),
            onImageSize: sizes.add,
          ),
        ),
      ),
    );
    final finder = find.byType(RawImage);
    ui.Image? firstImage;
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 4)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      firstImage = tester.widget<RawImage>(finder).image;
      if (firstImage != null) break;
    }
    expect(firstImage, isNotNull);
    expect(sizes, [const Size(12, 20)]);
    // A query, not an observer: attaching another full listener would make
    // the engine animate even though Image correctly honors TickerMode.
    final status = await FileImage(file)
        .obtainCacheStatus(configuration: ImageConfiguration.empty);
    expect(status?.live, isFalse);
    final copy = firstImage!.clone();
    try {
      final bytes = await tester.runAsync(
        () => copy.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      expect(
        [
          for (var channel = 0; channel < 4; channel++)
            bytes!.getUint8(channel),
        ],
        [197, 23, 73, 255],
      );
    } finally {
      copy.dispose();
    }

    await tester.pump(const Duration(milliseconds: 320));
    expect(tester.widget<RawImage>(finder).image, same(firstImage));
    await tester.pumpWidget(const SizedBox());
  });
}

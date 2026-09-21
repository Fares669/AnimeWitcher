import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/subsampling/ffi_image_decoder.dart';
import 'package:animewitcher/features/manga/reader/subsampling/subsampling_scale_image_view.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() async {
    await ffiImageDecoder.stop();
  });
  testWidgets('downloaded paged image uses Mangayomi subsampling renderer', (
    tester,
  ) async {
    final temp = await Directory.systemTemp.createTemp('aw_ssiv_page_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/page.bmp');
    await file.writeAsBytes(_bmp32());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaPageImage(
            page: MangaPage(index: 0, imageUrl: file.uri.toString()),
            settings: const MangaReaderSettings(),
            fit: BoxFit.contain,
            expand: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SubsamplingScaleImageView), findsOneWidget);
  });
}

List<int> _bmp32() => <int>[
  0x42, 0x4d, 62, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
  40, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 32, 0,
  0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 255, 255, 0, 255, 0, 255,
];

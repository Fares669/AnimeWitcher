import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/subsampling/subsampling_scale_image_view.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_continuous_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('network paged image uses Mangayomi subsampling renderer', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 800,
            child: MangaPageImage(
              page: MangaPage(
                index: 0,
                imageUrl: 'https://example.test/page.webp',
                headers: <String, String>{'Referer': 'https://example.test/'},
              ),
              settings: MangaReaderSettings(),
              fit: BoxFit.contain,
              expand: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SubsamplingScaleImageView), findsOneWidget);
    final renderer = tester.widget<SubsamplingScaleImageView>(
      find.byType(SubsamplingScaleImageView),
    );
    expect(renderer.image, isA<CachedNetworkImageProvider>());
  });

  testWidgets('vertical continuous page uses Mangayomi min-subsampling renderer', (
    tester,
  ) async {
    final file = await _tempBmp('continuous');
    addTearDown(() => file.parent.delete(recursive: true));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 800,
            child: MangaContinuousReader(
              pages: <MangaPage>[
                MangaPage(index: 0, imageUrl: file.uri.toString()),
              ],
              initialPage: 0,
              scrollDirection: Axis.vertical,
              reverse: false,
              settings: const MangaReaderSettings(),
              onPageChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('manga-reader-min-subsampling')),
      findsOneWidget,
    );
  });

  testWidgets('webtoon page uses Mangayomi min-subsampling renderer', (
    tester,
  ) async {
    final file = await _tempBmp('webtoon');
    addTearDown(() => file.parent.delete(recursive: true));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 800,
            child: MangaWebtoonReader(
              pages: <MangaPage>[
                MangaPage(index: 0, imageUrl: file.uri.toString()),
              ],
              initialPage: 0,
              settings: const MangaReaderSettings(),
              onPageChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('manga-reader-min-subsampling')),
      findsOneWidget,
    );
  });
}

Future<File> _tempBmp(String suffix) async {
  final dir = await Directory.systemTemp.createTemp('aw_ssiv_$suffix');
  final file = File('${dir.path}/page.bmp');
  await file.writeAsBytes(_bmp32());
  return file;
}

List<int> _bmp32() => <int>[
  0x42, 0x4d, 62, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
  40, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 32, 0,
  0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 255, 255, 0, 255, 0, 255,
];

import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/subsampling/subsampling_scale_image_view.dart' as ssiv;
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_page_loading.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('smart fit maps to Mangayomi subsampling smart-fit semantics', () {
    expect(
      mangaReaderMinimumScaleType(MangaReaderScaleType.smartFit),
      ssiv.ScaleType.smartFit,
    );
    expect(
      mangaReaderMinimumScaleType(MangaReaderScaleType.fitScreen),
      ssiv.ScaleType.centerInside,
    );
    expect(
      mangaReaderMinimumScaleType(MangaReaderScaleType.fitWidth),
      ssiv.ScaleType.fitWidth,
    );
    expect(
      mangaReaderMinimumScaleType(MangaReaderScaleType.fitHeight),
      ssiv.ScaleType.fitHeight,
    );
  });

  test('Mangayomi loading placeholder reserves eighty percent of viewport', () {
    expect(mangaReaderPageLoadingExtent(const Size(400, 1000)), 800);
  });

  test('Mangayomi loading ring exposes downloaded byte progress', () {
    expect(
      mangaReaderChunkProgress(
        const ImageChunkEvent(
          cumulativeBytesLoaded: 50,
          expectedTotalBytes: 200,
        ),
      ),
      0.25,
    );
    expect(
      mangaReaderChunkProgress(
        const ImageChunkEvent(
          cumulativeBytesLoaded: 50,
          expectedTotalBytes: null,
        ),
      ),
      isNull,
    );
  });

  test('network paged images route to Mangayomi paged subsampling', () {
    const page = MangaPage(
      index: 0,
      imageUrl: 'https://example.test/page.webp',
      headers: <String, String>{'Referer': 'https://example.test/'},
    );

    expect(
      mangaPageImageTier(page: page, expand: true),
      MangaPageImageTier.pagedSubsampling,
    );
    final provider = mangaPageImageProvider(page);
    expect(provider, isA<CachedNetworkImageProvider>());
    expect(
      (provider as CachedNetworkImageProvider).headers,
      page.headers,
    );
  });

  test('network continuous images route to Mangayomi min subsampling', () {
    const page = MangaPage(
      index: 0,
      imageUrl: 'https://example.test/continuous.webp',
    );

    expect(
      mangaPageImageTier(page: page, expand: false),
      MangaPageImageTier.continuousSubsampling,
    );
    expect(mangaPageImageProvider(page), isA<CachedNetworkImageProvider>());
  });

  test('downloaded static images route through subsampling without decoding', () async {
    final temp = await Directory.systemTemp.createTemp('aw_ssiv_route_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/page.webp');
    await file.writeAsBytes(const <int>[1]);

    final page = MangaPage(index: 0, imageUrl: file.uri.toString());
    expect(
      mangaPageImageTier(page: page, expand: true),
      MangaPageImageTier.pagedSubsampling,
    );
    expect(
      mangaPageImageTier(page: page, expand: false),
      MangaPageImageTier.continuousSubsampling,
    );
    expect(mangaPageImageProvider(page), isA<FileImage>());
  });

  test('GIF stays on animated Flutter image path', () {
    const page = MangaPage(
      index: 0,
      imageUrl: 'https://example.test/page.gif',
    );

    expect(
      mangaPageImageTier(page: page, expand: true),
      MangaPageImageTier.animated,
    );
    expect(
      mangaPageImageTier(page: page, expand: false),
      MangaPageImageTier.animated,
    );
  });
  testWidgets('loaded page keeps its image state after leaving the viewport', (
    tester,
  ) async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_keepalive_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final file = File('${temp.path}/page.gif');
    await file.writeAsBytes(const <int>[
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00,
      0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
      0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x01, 0x00,
      0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00,
      0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44,
      0x01, 0x00, 0x3b,
    ]);
    final page = MangaPage(index: 0, imageUrl: file.uri.toString());
    const pageKey = ValueKey<String>('kept-manga-page');
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 400,
          child: ListView.builder(
            controller: controller,
            itemCount: 8,
            itemBuilder: (context, index) => SizedBox(
              height: 400,
              child: index == 0
                  ? MangaPageImage(key: pageKey, page: page)
                  : Text('filler-$index'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = tester.state<State<StatefulWidget>>(find.byKey(pageKey));

    controller.jumpTo(2400);
    await tester.pumpAndSettle();
    controller.jumpTo(0);
    await tester.pumpAndSettle();

    final after = tester.state<State<StatefulWidget>>(find.byKey(pageKey));
    expect(identical(after, before), isTrue);
  });


}

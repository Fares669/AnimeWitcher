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
    final headers = (provider as CachedNetworkImageProvider).headers!;
    expect(headers['Referer'], page.headers['Referer']);
    final userAgents = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'user-agent')
        .map((entry) => entry.value)
        .toList();
    expect(userAgents, hasLength(1));
    expect(userAgents.single, isNot(contains('Dart/')));
  });

  test('image request headers preserve a source user agent case-insensitively', () {
    const page = MangaPage(
      index: 0,
      imageUrl: 'https://example.test/protected.webp',
      headers: <String, String>{'user-agent': 'Custom/1.0'},
    );

    final provider = mangaPageImageProvider(page) as CachedNetworkImageProvider;
    final userAgents = provider.headers!.entries
        .where((entry) => entry.key.toLowerCase() == 'user-agent')
        .map((entry) => entry.value)
        .toList();

    expect(userAgents, <String>['Custom/1.0']);
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
  test('header refresh automatically runs the cache-evicting retry path', () {
    final source = File(
      'lib/features/manga/reader/widgets/manga_page_image.dart',
    ).readAsStringSync();
    final updateStart = source.indexOf('void didUpdateWidget');
    final updateEnd = source.indexOf('void _listenForImageSize', updateStart);
    expect(updateStart, greaterThanOrEqualTo(0));
    expect(updateEnd, greaterThan(updateStart));

    final updateBlock = source.substring(updateStart, updateEnd);
    expect(updateBlock, contains('unawaited(_retry())'));
    expect(
      source,
      contains(
        'await CachedNetworkImage.evictFromCache(widget.page.imageUrl)',
      ),
    );
  });

  testWidgets(
    'same network URL remounts subsampling when refreshed headers change',
    (tester) async {
      var page = const MangaPage(
        index: 0,
        imageUrl: 'https://example.test/protected.webp',
      );
      late StateSetter rebuild;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return MangaPageImage(
                key: const ValueKey<String>('protected-page'),
                page: page,
                expand: true,
              );
            },
          ),
        ),
      );
      await tester.pump();

      final first = tester.widget<ssiv.SubsamplingScaleImageView>(
        find.byType(ssiv.SubsamplingScaleImageView),
      );

      rebuild(() {
        page = const MangaPage(
          index: 0,
          imageUrl: 'https://example.test/protected.webp',
          headers: <String, String>{
            'Referer': 'https://mangalik.net/manga/example/chapter-1/',
          },
        );
      });
      await tester.pump();
      Key? refreshedKey;
      for (var i = 0; i < 20 && refreshedKey == first.key; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        refreshedKey = tester
            .widget<ssiv.SubsamplingScaleImageView>(
              find.byType(ssiv.SubsamplingScaleImageView),
            )
            .key;
      }

      expect(refreshedKey, isNot(first.key));
    },
  );

  test('reader image failures emit the diagnostic network probe', () {
    final source = File(
      'lib/features/manga/reader/widgets/manga_page_image.dart',
    ).readAsStringSync();
    final diagnosticsSource = File(
      'lib/core/services/manga_reader_diagnostic_log.dart',
    ).readAsStringSync();

    expect(source, contains("record('image.error'"));
    expect(source, contains('mangaReaderDiagnostics.probeImage('));
    expect(source, contains("record('image.loaded'"));
    expect(
      diagnosticsSource,
      contains('request.headers.value(HttpHeaders.userAgentHeader)'),
    );
    expect(
      diagnosticsSource,
      isNot(contains("'probeUserAgent': client.userAgent")),
    );
  });

  test('continuous subsampling forwards image failures to reader refresh', () {
    final source = File(
      'lib/features/manga/reader/subsampling/manga_min_subsampling_image.dart',
    ).readAsStringSync();

    expect(source, contains('final VoidCallback? onImageError;'));
    expect(source, contains('onError: (_) => onImageError?.call()'));
  });

  testWidgets('page image state survives leaving the viewport', (tester) async {
    final page = MangaPage(
      index: 0,
      imageUrl: Uri.file('/definitely-missing/aw-reader-page.gif').toString(),
    );
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
    await tester.pump();

    final before = tester.state<State<StatefulWidget>>(find.byKey(pageKey));

    controller.jumpTo(2400);
    await tester.pump();
    controller.jumpTo(0);
    await tester.pump();

    final after = tester.state<State<StatefulWidget>>(find.byKey(pageKey));
    expect(identical(after, before), isTrue);
  });


}

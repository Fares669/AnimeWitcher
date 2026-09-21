import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}

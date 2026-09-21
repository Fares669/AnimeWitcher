import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('downloaded paged image selects Mangayomi subsampling renderer tier', () async {
    final temp = await Directory.systemTemp.createTemp('aw_ssiv_page_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/page.bmp');
    await file.writeAsBytes(const <int>[0x42, 0x4d]);

    final page = MangaPage(index: 0, imageUrl: file.uri.toString());

    expect(
      mangaPageImageTier(page: page, expand: true),
      MangaPageImageTier.pagedSubsampling,
    );
  });
}

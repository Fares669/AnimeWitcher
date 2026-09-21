import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_image_actions.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reader image actions load downloaded page bytes', () async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_action_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/page.webp');
    await file.writeAsBytes(<int>[1, 2, 3, 4]);

    final bytes = await loadMangaReaderPageBytes(
      MangaPage(index: 0, imageUrl: file.uri.toString()),
      Dio(),
    );

    expect(bytes, Uint8List.fromList(<int>[1, 2, 3, 4]));
  });

  test('reader image filename matches Mangayomi sanitization', () {
    expect(
      mangaReaderImageFileName(
        mangaTitle: 'Manga: Test?',
        chapterName: 'Chapter / 4',
        pageIndex: 7,
        extension: '.webp',
      ),
      'Manga_ Test_ Chapter _ 4 - 7.webp',
    );
  });

  test('reader image extension detects common formats', () {
    expect(
      mangaReaderImageExtension(
        Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]),
      ),
      '.png',
    );
    expect(
      mangaReaderImageExtension(
        Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xDB]),
      ),
      '.jpg',
    );
    expect(
      mangaReaderImageExtension(
        Uint8List.fromList(<int>[
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
        ]),
      ),
      '.webp',
    );
  });
}

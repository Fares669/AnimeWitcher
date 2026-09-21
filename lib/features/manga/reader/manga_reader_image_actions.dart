// Adapted from Mangayomi's image-actions path (Apache-2.0).
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/network/dio_client_provider.dart';

final mangaReaderImageActionsProvider = Provider<MangaReaderImageActions>(
  (ref) => MangaReaderImageActions(ref.watch(dioClientProvider)),
);

class MangaReaderImageActions {
  MangaReaderImageActions(this.dio);

  final Dio dio;

  Future<Uint8List> bytesFor(MangaPage page) =>
      loadMangaReaderPageBytes(page, dio);

  Future<File> savePage({
    required MangaPage page,
    required String mangaTitle,
    required String chapterName,
  }) async {
    final bytes = await bytesFor(page);
    final extension = mangaReaderImageExtension(bytes);
    return saveMangaReaderPageImage(
      bytes: bytes,
      fileName: mangaReaderImageFileName(
        mangaTitle: mangaTitle,
        chapterName: chapterName,
        pageIndex: page.index,
        extension: extension,
      ),
    );
  }

  Future<void> sharePage({
    required MangaPage page,
    required String mangaTitle,
    required String chapterName,
    Rect? sharePositionOrigin,
  }) async {
    final bytes = await bytesFor(page);
    final extension = mangaReaderImageExtension(bytes);
    await shareMangaReaderPageImage(
      bytes: bytes,
      fileName: mangaReaderImageFileName(
        mangaTitle: mangaTitle,
        chapterName: chapterName,
        pageIndex: page.index,
        extension: extension,
      ),
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  Future<File> saveCover({
    required MangaPage page,
    required String mangaTitle,
  }) async {
    final bytes = await bytesFor(page);
    final extension = mangaReaderImageExtension(bytes);
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory(
      p.join(root.path, 'MangaCovers'),
    );
    return saveMangaReaderPageImage(
      bytes: bytes,
      fileName: mangaReaderImageFileName(
        mangaTitle: mangaTitle,
        chapterName: 'cover',
        pageIndex: 0,
        extension: extension,
      ),
      directory: directory,
    );
  }
}

Future<Uint8List> loadMangaReaderPageBytes(MangaPage page, Dio dio) async {
  final uri = Uri.tryParse(page.imageUrl);
  if (uri != null && uri.scheme == 'file') {
    return File.fromUri(uri).readAsBytes();
  }

  final response = await dio.get<List<int>>(
    page.imageUrl,
    options: Options(
      responseType: ResponseType.bytes,
      headers: page.headers,
    ),
  );
  final data = response.data;
  if (data == null || data.isEmpty) {
    throw StateError('Reader page returned no image bytes.');
  }
  return Uint8List.fromList(data);
}

String mangaReaderImageExtension(Uint8List bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return '.png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return '.jpg';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return '.webp';
  }
  if (bytes.length >= 6) {
    final header = String.fromCharCodes(bytes.take(6));
    if (header == 'GIF87a' || header == 'GIF89a') return '.gif';
  }
  return '.jpg';
}

String mangaReaderImageMimeType(String extension) => switch (extension) {
  '.png' => 'image/png',
  '.webp' => 'image/webp',
  '.gif' => 'image/gif',
  _ => 'image/jpeg',
};

String mangaReaderImageFileName({
  required String mangaTitle,
  required String chapterName,
  required int pageIndex,
  required String extension,
}) {
  final stem = '$mangaTitle $chapterName - $pageIndex'.replaceAll(
    RegExp(r'[^a-zA-Z0-9 .()\-\s]'),
    '_',
  );
  return '$stem$extension';
}

Future<File> saveMangaReaderPageImage({
  required Uint8List bytes,
  required String fileName,
  Directory? directory,
}) async {
  final targetDirectory = directory ??
      Directory(
        p.join(
          (await getApplicationDocumentsDirectory()).path,
          'Pictures',
          'AnimeWitcher',
        ),
      );
  if (!await targetDirectory.exists()) {
    await targetDirectory.create(recursive: true);
  }
  final file = File(p.join(targetDirectory.path, p.basename(fileName)));
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<void> shareMangaReaderPageImage({
  required Uint8List bytes,
  required String fileName,
  Rect? sharePositionOrigin,
}) async {
  final extension = p.extension(fileName).toLowerCase();
  if (Platform.isLinux) {
    final file = await saveMangaReaderPageImage(
      bytes: bytes,
      fileName: fileName,
    );
    await Clipboard.setData(ClipboardData(text: file.path));
    return;
  }

  await SharePlus.instance.share(
    ShareParams(
      files: <XFile>[
        XFile.fromData(
          bytes,
          name: fileName,
          mimeType: mangaReaderImageMimeType(extension),
        ),
      ],
      sharePositionOrigin: sharePositionOrigin,
    ),
  );
}

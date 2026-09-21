// Adapted from Mangayomi's ChapterCache (Apache-2.0).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/domain/entity/manga.dart';

class MangaReaderPageCache {
  MangaReaderPageCache({Directory? cacheDirectory})
    : _customCacheDirectory = cacheDirectory;

  static const String cacheFolderName = 'manga_reader_chapter_cache';
  static const int maxCacheSizeBytes = 100 * 1024 * 1024;

  final Directory? _customCacheDirectory;

  String getKey(String mangaId, MangaChapter chapter) =>
      '${mangaId.trim()}_${chapter.url}';

  Future<Directory> _directory() async {
    final custom = _customCacheDirectory;
    if (custom != null) {
      if (!await custom.exists()) await custom.create(recursive: true);
      return custom;
    }
    final root = await getTemporaryDirectory();
    final directory = Directory(p.join(root.path, cacheFolderName));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<File> _file(String mangaId, MangaChapter chapter) async {
    final directory = await _directory();
    final hash = md5.convert(utf8.encode(getKey(mangaId, chapter))).toString();
    return File(p.join(directory.path, '$hash.json'));
  }

  Future<List<MangaPage>?> get(
    String mangaId,
    MangaChapter chapter,
  ) async {
    try {
      final file = await _file(mangaId, chapter);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final rawPages = decoded['pages'];
      if (rawPages is! List || rawPages.isEmpty) return null;

      final pages = <MangaPage>[];
      for (final raw in rawPages) {
        if (raw is! Map) continue;
        final imageUrl = raw['imageUrl']?.toString().trim() ?? '';
        if (imageUrl.isEmpty) continue;
        final headersRaw = raw['headers'];
        final headers = <String, String>{
          if (headersRaw is Map)
            for (final entry in headersRaw.entries)
              entry.key.toString(): entry.value.toString(),
        };
        pages.add(
          MangaPage(
            index: raw['index'] is num
                ? (raw['index'] as num).toInt()
                : pages.length,
            imageUrl: imageUrl,
            headers: headers,
          ),
        );
      }
      return pages.isEmpty ? null : List<MangaPage>.unmodifiable(pages);
    } catch (_) {
      return null;
    }
  }

  Future<void> put(
    String mangaId,
    MangaChapter chapter,
    List<MangaPage> pages,
  ) async {
    if (pages.isEmpty || pages.every((page) => page.imageUrl.trim().isEmpty)) {
      return;
    }
    try {
      final file = await _file(mangaId, chapter);
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'chapterUrl': chapter.url,
          'pages': <Map<String, Object?>>[
            for (final page in pages)
              <String, Object?>{
                'index': page.index,
                'imageUrl': page.imageUrl,
                if (page.headers.isNotEmpty) 'headers': page.headers,
              },
          ],
        }),
        flush: true,
      );
      await trim();
    } catch (_) {}
  }

  Future<void> remove(String mangaId, MangaChapter chapter) async {
    try {
      final file = await _file(mangaId, chapter);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> trim({int maxBytes = maxCacheSizeBytes}) async {
    try {
      final directory = await _directory();
      final files = directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList(growable: false);
      final entries = <({File file, int size, DateTime modified})>[];
      var total = 0;
      for (final file in files) {
        try {
          final stat = file.statSync();
          total += stat.size;
          entries.add((file: file, size: stat.size, modified: stat.modified));
        } catch (_) {}
      }
      if (total <= maxBytes) return;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (total <= maxBytes) break;
        try {
          await entry.file.delete();
          total -= entry.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<int> clear() async {
    var deleted = 0;
    try {
      final directory = await _directory();
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          await entity.delete();
          deleted++;
        } catch (_) {}
      }
    } catch (_) {}
    return deleted;
  }
}

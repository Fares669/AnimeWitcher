// Adapted from Mangayomi's ChapterCache (Apache-2.0).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/utils/local_file_io.dart';

class MangaReaderPageCache {
  MangaReaderPageCache({Directory? cacheDirectory})
    : _customCacheDirectory = cacheDirectory;

  static const String cacheFolderName = 'manga_reader_chapter_cache';
  static const int maxCacheSizeBytes = 100 * 1024 * 1024;

  final Directory? _customCacheDirectory;
  _PageCacheMaintenance? _lastMaintenance;
  static int _temporaryFileId = 0;

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
    final key = '${mangaId.trim()}_${chapter.url}';
    final hash = md5.convert(utf8.encode(key)).toString();
    return File(p.join(directory.path, '$hash.json'));
  }

  Future<List<MangaPage>?> get(String mangaId, MangaChapter chapter) async {
    try {
      final file = await _file(mangaId, chapter);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final savedAt = decoded['timestamp'];
      if (savedAt is! int ||
          DateTime.now().millisecondsSinceEpoch - savedAt >
              const Duration(minutes: 5).inMilliseconds) {
        return null;
      }
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
      final maintenance = _lastMaintenance = _PageCacheMaintenance.forFile(
        file,
      );
      await maintenance.mutate(file.path, () async {
        final stamp = DateTime.now();
        final id = _temporaryFileId++;
        final temp = File(
          '${file.path}.$pid.${stamp.microsecondsSinceEpoch}.$id.tmp',
        );
        try {
          await temp.writeAsString(
            jsonEncode(<String, Object?>{
              'timestamp': stamp.millisecondsSinceEpoch,
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
          // The published name is never a partially written JSON file.
          await temp.rename(file.path);
        } catch (_) {
          try {
            await temp.delete();
          } catch (_) {}
          rethrow;
        }
      }, requestTrim: true);
    } catch (_) {}
  }

  Future<void> remove(String mangaId, MangaChapter chapter) async {
    try {
      final file = await _file(mangaId, chapter);
      final maintenance = _lastMaintenance = _PageCacheMaintenance.forFile(
        file,
      );
      await maintenance.mutate(file.path, () async {
        if (await file.exists()) await file.delete();
      });
    } catch (_) {}
  }

  /// Used for explicit shutdown. Chapter loads wait only for publication.
  Future<void> waitForMaintenance() async {
    await _lastMaintenance?.settled;
  }
}

typedef _CacheEntry = ({
  String path,
  int size,
  DateTime modified,
  DateTime changed,
});
typedef _CacheTrimPlan = ({int totalBytes, List<_CacheEntry> entries});

// Instances sharing a directory share one scan, including adjacent chapter
// preloads. A write during a scan invalidates that snapshot and requests one
// follow-up; it does not create a worker per chapter or wait for the scan.
final class _PageCacheMaintenance {
  _PageCacheMaintenance(this.path);

  static final _active = <String, _PageCacheMaintenance>{};
  final String path;
  final _mutations = <String, Future<void>>{};
  bool _dirty = false;
  Future<void>? _trim;
  Future<void>? _eviction;
  final _settled = Completer<void>();

  static _PageCacheMaintenance forFile(File file) {
    final path = p.normalize(p.absolute(file.parent.path));
    return _active.putIfAbsent(path, () => _PageCacheMaintenance(path));
  }

  Future<void> get settled => _settled.future;

  Future<void> mutate(
    String filePath,
    Future<void> Function() operation, {
    bool requestTrim = false,
  }) async {
    final key = p.normalize(p.absolute(filePath));
    if (_trim != null) _dirty = true;
    final predecessor = _mutations[key];
    final eviction = _eviction;
    final tracked = Completer<void>();
    _mutations[key] = tracked.future;
    try {
      if (predecessor != null) await predecessor;
      if (eviction != null) await eviction;
      await operation();
      if (requestTrim) _dirty = true;
    } finally {
      tracked.complete();
      if (identical(_mutations[key], tracked.future)) {
        unawaited(_mutations.remove(key));
      }
      _schedule();
    }
  }

  void _schedule() {
    if (_trim != null || _mutations.isNotEmpty) return;
    if (!_dirty) {
      _active.remove(path);
      _settled.complete();
      return;
    }
    _dirty = false;
    _trim = _trimIfNeeded(path).whenComplete(() {
      _trim = null;
      _schedule();
    });
  }

  Future<void> _trimIfNeeded(String directoryPath) async {
    try {
      // Only the path is sent to the worker. The old list/stat loop must not
      // block drawing, nor make successful puts wait for maintenance.
      final plan = await _scanReaderCache(directoryPath);
      if (plan == null || _dirty || _mutations.isNotEmpty) return;
      // New mutations wait only while victims are being removed (most scans
      // have none). Old snapshots cannot delete an in-app replacement.
      final eviction = _deleteCacheEntries(plan);
      _eviction = eviction;
      try {
        await eviction;
      } finally {
        _eviction = null;
      }
    } catch (_) {}
  }
}

Future<_CacheTrimPlan?> _scanReaderCache(String path) => runLocalFileIo(() {
  final entries = <_CacheEntry>[];
  var total = 0;
  for (final entity in Directory(path).listSync(followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    final stat = entity.statSync();
    if (stat.type != FileSystemEntityType.file) continue;
    total += stat.size;
    entries.add((
      path: entity.path,
      size: stat.size,
      modified: stat.modified,
      changed: stat.changed,
    ));
  }
  if (total <= MangaReaderPageCache.maxCacheSizeBytes) return null;
  entries.sort((a, b) => a.modified.compareTo(b.modified));
  return (totalBytes: total, entries: entries);
});

Future<void> _deleteCacheEntries(_CacheTrimPlan plan) => runLocalFileIo(() {
  var total = plan.totalBytes;
  for (final entry in plan.entries) {
    if (total <= MangaReaderPageCache.maxCacheSizeBytes) break;
    final file = File(entry.path);
    try {
      final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        total -= entry.size;
        continue;
      }
      // Settings-level cache clearing bypasses the coordinator. Stop instead
      // of pruning a recreated or linked entry using an obsolete snapshot.
      if (type != FileSystemEntityType.file) return;
      final stat = file.statSync();
      if (stat.size != entry.size ||
          stat.modified != entry.modified ||
          stat.changed != entry.changed) {
        return;
      }
      file.deleteSync();
      total -= entry.size;
    } catch (_) {
      // Best effort: a locked old file does not block pruning the next one.
    }
  }
});

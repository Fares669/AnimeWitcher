import 'dart:io';

// Keep this dependency-free safety check runnable with plain Dart before pub get.
// ignore: avoid_relative_lib_imports
import '../lib/core/storage/scoped_cache_files.dart';

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('aw_cache_test_');
  try {
    final shared = await Directory('${root.path}/shared').create();
    final owned = await Directory('${root.path}/manga_reader_chapter_cache')
        .create();
    final outside = await Directory('${root.path}/downloads').create();
    final tracked = await File('${shared.path}/tracked.jpg')
        .writeAsBytes([1, 2, 3]);
    final unrelated = await File('${shared.path}/other-app.jpg')
        .writeAsBytes([4, 5]);
    final download = await File('${outside.path}/episode.mp4')
        .writeAsBytes([6, 7, 8, 9]);
    await File('${owned.path}/chapter.json').writeAsBytes([1, 2]);
    await Link('${owned.path}/external').create(outside.path);
    final files = ScopedCacheFiles(
      trackedFiles: [tracked],
      trackedDirectories: [shared],
      ownedDirectories: [owned],
    );
    if (await files.bytes() != 5) throw StateError('counts unrelated files');
    await files.clear();
    if (await files.bytes() != 0) throw StateError('owned bytes remain');
    if (!await unrelated.exists() ||
        !await download.exists() ||
        !await root.exists()) {
      throw StateError('deleted unrelated data');
    }
    await files.clear(); // Idempotent and does not follow links.
    final linkedRoot = Link('${root.path}/linked-cache');
    await linkedRoot.create(outside.path);
    final escaped = ScopedCacheFiles(
      trackedFiles: [File('${linkedRoot.path}/episode.mp4')],
      trackedDirectories: [Directory(linkedRoot.path)],
      ownedDirectories: [],
    );
    var rejected = false;
    try {
      await escaped.clear();
    } on FileSystemException {
      rejected = true;
    }
    if (!rejected || !await download.exists()) {
      throw StateError('linked root escaped');
    }
    final traversal = ScopedCacheFiles(
      trackedFiles: [File('${shared.path}/../downloads/episode.mp4')],
      trackedDirectories: [shared],
      ownedDirectories: [],
    );
    rejected = false;
    try {
      await traversal.clear();
    } on FileSystemException {
      rejected = true;
    }
    if (!rejected || !await download.exists()) {
      throw StateError('path traversal escaped');
    }
    stdout.writeln(
      'PASS: exact owned bytes; clear; unrelated/download files and root preserved; symlink excluded; repeated clear',
    );
  } finally {
    await root.delete(recursive: true);
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'failed manifest rename preserves the last durable chapter checkpoint',
    () async {
      final directory = await Directory.systemTemp.createTemp('aw_manifest_');
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        p.join(directory.path, MangaChapterManifestV2.fileName),
      );
      const original = MangaChapterManifestV2(
        version: MangaChapterManifestV2.currentVersion,
        mangaId: 'manga',
        chapterId: 'chapter',
        pageCount: 2,
        completedIndexes: <int>{0},
        isComplete: false,
      );
      await original.writeTo(directory);
      final replacement = original.copyWith(
        completedIndexes: <int>{0, 1},
        isComplete: true,
      );

      final realFiles = <String, File>{
        file.path: file,
        '${file.path}.tmp': File('${file.path}.tmp'),
      };
      await IOOverrides.runZoned(
        () => expectLater(
          replacement.writeTo(directory),
          throwsA(isA<FileSystemException>()),
        ),
        createFile: (path) => _RenameFailingFile(realFiles[path]!),
      );

      expect(await file.exists(), isTrue);
      expect(jsonDecode(await file.readAsString()), original.toJson());
      expect(
        (await MangaChapterManifestV2.readFrom(directory))!.completedIndexes,
        <int>{0},
      );
    },
  );

  test('manifest replacement publishes the complete new checkpoint', () async {
    final directory = await Directory.systemTemp.createTemp(
      'aw_manifest_replace_',
    );
    addTearDown(() => directory.delete(recursive: true));
    const original = MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'manga',
      chapterId: 'chapter',
      pageCount: 2,
      completedIndexes: <int>{0},
      isComplete: false,
    );
    await original.writeTo(directory);
    await original
        .copyWith(completedIndexes: <int>{0, 1}, isComplete: true)
        .writeTo(directory);

    final restored = await MangaChapterManifestV2.readFrom(directory);
    expect(restored!.isComplete, isTrue);
    expect(restored.completedIndexes, <int>{0, 1});
    expect(
      await File(p.join(directory.path, 'manifest.json.tmp')).exists(),
      isFalse,
    );
  });
}

final class _RenameFailingFile implements File {
  _RenameFailingFile(this.file);
  final File file;

  @override
  String get path => file.path;

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => file.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );

  @override
  Future<File> rename(String newPath) async =>
      throw FileSystemException('Simulated rename failure', path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

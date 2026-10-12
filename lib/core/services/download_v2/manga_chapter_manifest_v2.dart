import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Supported image signature only; decoding remains the reader's job.
Future<bool> isMangaPageImageV2(File file) async {
  RandomAccessFile? input;
  try {
    input = await file.open();
    final header = await input.read(64);
    bool matches(int offset, List<int> bytes) {
      if (offset + bytes.length > header.length) return false;
      for (var index = 0; index < bytes.length; index++) {
        if (header[offset + index] != bytes[index]) return false;
      }
      return true;
    }

    if (matches(0, const <int>[0xff, 0xd8, 0xff]) ||
        matches(0, const <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) ||
        matches(0, const <int>[71, 73, 70, 56, 55, 97]) ||
        matches(0, const <int>[71, 73, 70, 56, 57, 97]) ||
        (matches(0, const <int>[82, 73, 70, 70]) &&
            matches(8, const <int>[87, 69, 66, 80]))) {
      return true;
    }
    if (header.length < 16 || !matches(4, const <int>[102, 116, 121, 112])) {
      return false;
    }

    var boxSize =
        (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];
    var majorOffset = 8;
    if (boxSize == 1) {
      if (header.length < 24) return false;
      boxSize = 0;
      for (var index = 8; index < 16; index++) {
        boxSize = (boxSize << 8) | header[index];
      }
      if (boxSize < 24) return false;
      majorOffset = 16;
    }
    final headerEnd = boxSize == 0 || boxSize > header.length
        ? header.length
        : boxSize;
    if (headerEnd < majorOffset + 8) return false;
    bool avifBrand(int offset) =>
        matches(offset, const <int>[97, 118, 105, 102]) ||
        matches(offset, const <int>[97, 118, 105, 115]);
    if (avifBrand(majorOffset)) return true;
    for (var offset = majorOffset + 8; offset + 4 <= headerEnd; offset += 4) {
      if (avifBrand(offset)) return true;
    }
    return false;
  } on FileSystemException {
    return false;
  } finally {
    await input?.close();
  }
}

/// Durable chapter-level checkpoint. Page URLs stay outside this file because
/// they are transport metadata and may rotate between launches.
final class MangaChapterManifestV2 {
  const MangaChapterManifestV2({
    required this.version,
    required this.mangaId,
    required this.chapterId,
    required this.pageCount,
    required this.completedIndexes,
    required this.isComplete,
    this.pageDigests = const <int, String>{},
  });

  static const int currentVersion = 1;
  static const String fileName = 'manifest.json';

  final int version;
  final String mangaId;
  final String chapterId;
  final int pageCount;
  final Set<int> completedIndexes;
  final bool isComplete;
  final Map<int, String> pageDigests;

  static Future<String> pageDigest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<bool> isPageValid(int index, File file) async {
    try {
      if (!await file.exists() || await file.length() <= 0) return false;
      final expected = pageDigests[index];
      // Legacy checkpoints have no hash; retain existing offline chapters.
      if (expected == null) return true;
      return await isMangaPageImageV2(file) && await pageDigest(file) == expected;
    } on FileSystemException {
      return false;
    }
  }

  MangaChapterManifestV2 copyWith({
    Set<int>? completedIndexes,
    bool? isComplete,
    Map<int, String>? pageDigests,
  }) {
    return MangaChapterManifestV2(
      version: version,
      mangaId: mangaId,
      chapterId: chapterId,
      pageCount: pageCount,
      completedIndexes: completedIndexes ?? this.completedIndexes,
      isComplete: isComplete ?? this.isComplete,
      pageDigests: pageDigests ?? this.pageDigests,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'mangaId': mangaId,
    'chapterId': chapterId,
    'pageCount': pageCount,
    'completedIndexes': completedIndexes.toList()..sort(),
    'isComplete': isComplete,
    if (pageDigests.isNotEmpty)
      'pageDigests': pageDigests.map((index, hash) => MapEntry('$index', hash)),
  };

  static MangaChapterManifestV2? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final version = map['version'];
    final mangaId = map['mangaId'];
    final chapterId = map['chapterId'];
    final pageCount = map['pageCount'];
    final rawCompleted = map['completedIndexes'];
    if (version is! int ||
        version != currentVersion ||
        mangaId is! String ||
        mangaId.trim().isEmpty ||
        chapterId is! String ||
        chapterId.trim().isEmpty ||
        pageCount is! int ||
        pageCount < 0 ||
        rawCompleted is! List) {
      return null;
    }

    final completed = <int>{};
    for (final value in rawCompleted) {
      if (value is int && value >= 0 && value < pageCount) completed.add(value);
    }

    final pageDigests = <int, String>{};
    final rawDigests = map['pageDigests'];
    if (rawDigests != null && rawDigests is! Map) return null;
    if (rawDigests is Map) {
      final validDigest = RegExp(r'^[a-f0-9]{64}$');
      for (final entry in rawDigests.entries) {
        final index = int.tryParse(entry.key.toString());
        if (index == null || index < 0 || index >= pageCount) continue;
        final value = entry.value;
        pageDigests[index] = value is String && validDigest.hasMatch(value)
            ? value
            : 'invalid';
      }
    }

    return MangaChapterManifestV2(
      version: version,
      mangaId: mangaId,
      chapterId: chapterId,
      pageCount: pageCount,
      completedIndexes: completed,
      isComplete: map['isComplete'] == true && completed.length == pageCount,
      pageDigests: pageDigests,
    );
  }

  static Future<MangaChapterManifestV2?> readFrom(Directory directory) async {
    final file = File(p.join(directory.path, fileName));
    if (!await file.exists()) return null;
    try {
      return fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> writeTo(Directory directory) async {
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, fileName));
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(toJson()), flush: true);
    // Same-directory rename replaces the checkpoint atomically. Retain the
    // previous file if the OS cannot publish the new one.
    await temp.rename(file.path);
  }
}

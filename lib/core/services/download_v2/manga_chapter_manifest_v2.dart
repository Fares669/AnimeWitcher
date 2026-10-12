import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

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
      // Legacy checkpoints have no hash; do not discard offline chapters.
      return expected == null || await pageDigest(file) == expected;
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
    if (rawDigests is Map) {
      final validDigest = RegExp(r'^[a-f0-9]{64}
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
);
      for (final entry in rawDigests.entries) {
        final index = int.tryParse(entry.key.toString());
        final digest = entry.value;
        if (index != null &&
            completed.contains(index) &&
            digest is String &&
            validDigest.hasMatch(digest)) {
          pageDigests[index] = digest;
        }
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

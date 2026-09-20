import 'dart:convert';
import 'dart:io';

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
  });

  static const int currentVersion = 1;
  static const String fileName = 'manifest.json';

  final int version;
  final String mangaId;
  final String chapterId;
  final int pageCount;
  final Set<int> completedIndexes;
  final bool isComplete;

  MangaChapterManifestV2 copyWith({
    Set<int>? completedIndexes,
    bool? isComplete,
  }) {
    return MangaChapterManifestV2(
      version: version,
      mangaId: mangaId,
      chapterId: chapterId,
      pageCount: pageCount,
      completedIndexes: completedIndexes ?? this.completedIndexes,
      isComplete: isComplete ?? this.isComplete,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'mangaId': mangaId,
    'chapterId': chapterId,
    'pageCount': pageCount,
    'completedIndexes': completedIndexes.toList()..sort(),
    'isComplete': isComplete,
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

    return MangaChapterManifestV2(
      version: version,
      mangaId: mangaId,
      chapterId: chapterId,
      pageCount: pageCount,
      completedIndexes: completed,
      isComplete: map['isComplete'] == true && completed.length == pageCount,
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
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }
}

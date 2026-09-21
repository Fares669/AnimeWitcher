import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'storage_service.dart';

final class MangaReadingProgress {
  const MangaReadingProgress({
    required this.mangaId,
    required this.chapterId,
    required this.pageIndex,
    required this.pageCount,
    required this.updatedAt,
    this.isRead = false,
    this.isBookmarked = false,
  });

  final String mangaId;
  final String chapterId;
  final int pageIndex;
  final int pageCount;
  final int updatedAt;
  final bool isRead;
  final bool isBookmarked;

  MangaReadingProgress copyWith({
    int? pageIndex,
    int? pageCount,
    int? updatedAt,
    bool? isRead,
    bool? isBookmarked,
  }) {
    return MangaReadingProgress(
      mangaId: mangaId,
      chapterId: chapterId,
      pageIndex: pageIndex ?? this.pageIndex,
      pageCount: pageCount ?? this.pageCount,
      updatedAt: updatedAt ?? this.updatedAt,
      isRead: isRead ?? this.isRead,
      isBookmarked: isBookmarked ?? this.isBookmarked,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'mangaId': mangaId,
    'chapterId': chapterId,
    'pageIndex': pageIndex,
    'pageCount': pageCount,
    'updatedAt': updatedAt,
    'isRead': isRead,
    'isBookmarked': isBookmarked,
  };

  factory MangaReadingProgress.fromJson(Map<String, Object?> json) {
    int readInt(String key) =>
        int.tryParse(json[key]?.toString() ?? '') ?? 0;

    return MangaReadingProgress(
      mangaId: json['mangaId']?.toString().trim() ?? '',
      chapterId: json['chapterId']?.toString().trim() ?? '',
      pageIndex: readInt('pageIndex'),
      pageCount: readInt('pageCount'),
      updatedAt: readInt('updatedAt'),
      isRead: json['isRead'] == true,
      isBookmarked: json['isBookmarked'] == true,
    );
  }
}

class MangaReadingRepository {
  MangaReadingRepository(this._storage);

  final StorageService _storage;

  String _hash(String value) =>
      md5.convert(utf8.encode(value.trim())).toString();

  String _key(String mangaId, String chapterId) =>
      'manga_progress:' + _hash(mangaId) + ':' + _hash(chapterId);

  MangaReadingProgress? get(String mangaId, String chapterId) {
    final raw = _storage.getString(_key(mangaId, chapterId));
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final progress = MangaReadingProgress.fromJson(
        Map<String, Object?>.from(decoded),
      );
      if (progress.mangaId.isEmpty || progress.chapterId.isEmpty) return null;
      return progress;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(MangaReadingProgress progress) {
    final pageCount = progress.pageCount < 0 ? 0 : progress.pageCount;
    final maxPage = pageCount <= 0 ? 0 : pageCount - 1;
    final pageIndex = progress.pageIndex.clamp(0, maxPage).toInt();
    final normalized = progress.copyWith(
      pageIndex: pageIndex,
      pageCount: pageCount,
    );
    return _storage.setString(
      _key(progress.mangaId, progress.chapterId),
      jsonEncode(normalized.toJson()),
    );
  }

  Future<bool> toggleBookmark(String mangaId, String chapterId) async {
    final current = get(mangaId, chapterId);
    if (current == null) return false;
    final next = !current.isBookmarked;
    await save(
      current.copyWith(
        isBookmarked: next,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return next;
  }

  Future<void> markRead(
    String mangaId,
    String chapterId, {
    int pageCount = 1,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final current = get(mangaId, chapterId);
    final count = current == null
        ? pageCount.clamp(1, 1 << 30).toInt()
        : (current.pageCount <= 0
              ? pageCount.clamp(1, 1 << 30).toInt()
              : current.pageCount);
    await save(
      current?.copyWith(
            pageIndex: count - 1,
            pageCount: count,
            updatedAt: now,
            isRead: true,
          ) ??
          MangaReadingProgress(
            mangaId: mangaId,
            chapterId: chapterId,
            pageIndex: count - 1,
            pageCount: count,
            updatedAt: now,
            isRead: true,
          ),
    );
  }
}

final mangaReadingRepositoryProvider = Provider<MangaReadingRepository>((ref) {
  return MangaReadingRepository(ref.watch(storageServiceProvider));
});

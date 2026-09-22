import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_providers.dart';
import 'storage_service.dart';

typedef MangaCloudReadLookup = bool Function(String mangaId, String chapterId);
typedef MangaCloudReadSync = Future<void> Function(
  String mangaId,
  Iterable<String> chapterIds,
  bool read,
);

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

  int get pagesRead {
    if (pageCount <= 0) return 0;
    if (isRead) return pageCount;
    return (pageIndex + 1).clamp(0, pageCount).toInt();
  }

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
  MangaReadingRepository(
    this._storage, {
    MangaCloudReadLookup? isCloudRead,
    MangaCloudReadSync? syncReadStates,
    void Function()? onChanged,
  }) : _isCloudRead = isCloudRead,
       _syncReadStates = syncReadStates,
       _onChanged = onChanged;

  final StorageService _storage;
  final MangaCloudReadLookup? _isCloudRead;
  final MangaCloudReadSync? _syncReadStates;
  final void Function()? _onChanged;

  String _hash(String value) =>
      md5.convert(utf8.encode(value.trim())).toString();

  String _key(String mangaId, String chapterId) =>
      'manga_progress:' + _hash(mangaId) + ':' + _hash(chapterId);

  MangaReadingProgress? _local(String mangaId, String chapterId) {
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

  MangaReadingProgress? get(String mangaId, String chapterId) {
    final local = _local(mangaId, chapterId);
    final cloudRead = _isCloudRead?.call(mangaId, chapterId) ?? false;
    if (!cloudRead) return local;

    if (local == null) {
      return MangaReadingProgress(
        mangaId: mangaId,
        chapterId: chapterId,
        pageIndex: 0,
        pageCount: 0,
        updatedAt: 0,
        isRead: true,
      );
    }
    if (local.isRead) return local;
    return local.copyWith(
      isRead: true,
      pageIndex: local.pageCount > 0 ? local.pageCount - 1 : local.pageIndex,
    );
  }

  MangaReadingProgress _normalize(MangaReadingProgress progress) {
    final pageCount = progress.pageCount < 0 ? 0 : progress.pageCount;
    final maxPage = pageCount <= 0 ? 0 : pageCount - 1;
    final pageIndex = progress.pageIndex.clamp(0, maxPage).toInt();
    return progress.copyWith(pageIndex: pageIndex, pageCount: pageCount);
  }

  Future<void> _write(MangaReadingProgress progress) {
    return _storage.setString(
      _key(progress.mangaId, progress.chapterId),
      jsonEncode(progress.toJson()),
    );
  }

  Future<void> _sync(
    String mangaId,
    Iterable<String> chapterIds,
    bool read,
  ) async {
    final callback = _syncReadStates;
    if (callback == null) return;
    try {
      await callback(mangaId, chapterIds, read);
    } catch (_) {
      // The AnimeWitcher account service keeps a durable pending mutation.
      // Local reading progress remains immediately usable while offline.
    }
  }

  Future<void> save(MangaReadingProgress progress) async {
    final previous = _local(progress.mangaId, progress.chapterId);
    final cloudRead =
        _isCloudRead?.call(progress.mangaId, progress.chapterId) ?? false;
    final normalized = _normalize(progress);
    await _write(normalized);
    _onChanged?.call();

    if (normalized.isRead && previous?.isRead != true && !cloudRead) {
      await _sync(
        normalized.mangaId,
        <String>[normalized.chapterId],
        true,
      );
    }
  }

  Future<bool> toggleBookmark(String mangaId, String chapterId) async {
    final current = get(mangaId, chapterId);
    final next = !(current?.isBookmarked ?? false);
    final now = DateTime.now().millisecondsSinceEpoch;
    await save(
      current?.copyWith(
            isBookmarked: next,
            updatedAt: now,
          ) ??
          MangaReadingProgress(
            mangaId: mangaId,
            chapterId: chapterId,
            pageIndex: 0,
            pageCount: 0,
            updatedAt: now,
            isBookmarked: next,
          ),
    );
    return next;
  }

  Future<bool> toggleRead(
    String mangaId,
    String chapterId, {
    int pageCount = 1,
  }) async {
    final current = get(mangaId, chapterId);
    final next = !(current?.isRead ?? false);
    if (next) {
      await markRead(mangaId, chapterId, pageCount: pageCount);
    } else {
      await setReadStates(mangaId, <String>[chapterId], read: false);
    }
    return next;
  }

  Future<void> markRead(
    String mangaId,
    String chapterId, {
    int pageCount = 1,
  }) async {
    final current = _local(mangaId, chapterId);
    final count = current == null || current.pageCount <= 0
        ? pageCount.clamp(1, 1 << 30).toInt()
        : current.pageCount;
    await save(
      current?.copyWith(
            pageIndex: count - 1,
            pageCount: count,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            isRead: true,
          ) ??
          MangaReadingProgress(
            mangaId: mangaId,
            chapterId: chapterId,
            pageIndex: count - 1,
            pageCount: count,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            isRead: true,
          ),
    );
  }

  Future<void> setReadStates(
    String mangaId,
    Iterable<String> chapterIds, {
    required bool read,
  }) async {
    final ids = chapterIds
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (mangaId.trim().isEmpty || ids.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final chapterId in ids) {
      final current = _local(mangaId, chapterId);
      final count = current?.pageCount ?? 0;
      final next = current?.copyWith(
            pageIndex: read && count > 0 ? count - 1 : 0,
            pageCount: read ? count : 0,
            updatedAt: now,
            isRead: read,
          ) ??
          MangaReadingProgress(
            mangaId: mangaId,
            chapterId: chapterId,
            pageIndex: 0,
            pageCount: 0,
            updatedAt: now,
            isRead: read,
          );
      await _write(_normalize(next));
    }
    _onChanged?.call();
    await _sync(mangaId, ids, read);
  }
}

final mangaReadingRevisionProvider =
    NotifierProvider<MangaReadingRevision, int>(MangaReadingRevision.new);

class MangaReadingRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final mangaReadingRepositoryProvider = Provider<MangaReadingRepository>((ref) {
  ref.watch(accountDataRevisionProvider);
  return MangaReadingRepository(
    ref.watch(storageServiceProvider),
    isCloudRead: (mangaId, chapterId) {
      try {
        return ref
            .read(animeWitcherAccountServiceProvider)
            .isMangaChapterWatchedCached(mangaId, chapterId);
      } catch (_) {
        return false;
      }
    },
    syncReadStates: (mangaId, chapterIds, read) async {
      try {
        final service = ref.read(animeWitcherAccountServiceProvider);
        if (!service.isSignedIn) return;
        await service.setMangaChaptersWatched(
          mangaId: mangaId,
          chapterIds: chapterIds,
          watched: read,
        );
      } catch (_) {}
    },
    onChanged: () => ref.read(mangaReadingRevisionProvider.notifier).bump(),
  );
});

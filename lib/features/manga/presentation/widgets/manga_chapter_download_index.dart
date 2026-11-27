import 'package:background_downloader/background_downloader.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/services/download_v2/download_v2_identity.dart';
import '../../../../core/services/download_v2/download_v2_models.dart';
import '../../../library/presentation/downloads_provider.dart';

/// Fast repeated chapter lookups for one published Downloads snapshot.
///
/// Matches the one-shot helpers in downloads_provider: a match on any of the
/// normalized logical ID, chapter identity, or either URL suffices. A video
/// row never owns a manga chapter. When aliases disagree, the first complete
/// row in snapshot order wins, not whichever kind of key was looked up first.
final class MangaChapterDownloadIndex {
  MangaChapterDownloadIndex(this._items) {
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item.mediaKind != DownloadMediaKind.mangaChapter) continue;
      final status = item.status;
      final completeIndex = status == TaskStatus.complete ? i : null;
      switch (status) {
        case TaskStatus.running:
        case TaskStatus.enqueued:
        case TaskStatus.waitingToRetry:
        case TaskStatus.paused:
        case TaskStatus.complete:
          break;
        case TaskStatus.failed:
        case TaskStatus.notFound:
        case TaskStatus.canceled:
          continue;
      }

      final logicalId = item.logicalId?.trim() ?? '';
      if (logicalId.isNotEmpty) _add(_logicalIds, logicalId, completeIndex);
      final chapter = item.chapter;
      if (chapter != null) {
        _add(_chapters, _chapterKey(chapter), completeIndex);
        final url = chapter.url.trim();
        if (url.isNotEmpty) _add(_urls, url, completeIndex);
      }
      final url = item.trackingUrl.trim();
      if (url.isNotEmpty) _add(_urls, url, completeIndex);
    }
  }

  final List<DownloadItem> _items;
  // A null value is an active download; a non-null value is the earliest
  // completed row. containsKey distinguishes active from absent.
  final _logicalIds = <String, int?>{};
  final _chapters = <(String, String), int?>{};
  final _urls = <String, int?>{};

  static void _add<K>(Map<K, int?> index, K key, int? completeIndex) {
    if (completeIndex == null) {
      index.putIfAbsent(key, () => null);
    } else {
      index[key] ??= completeIndex;
    }
  }

  static (String, String) _chapterKey(MangaChapter chapter) =>
      (chapter.mangaId.trim(), chapter.id.trim());

  String? _logicalKey((String, String) chapter) {
    if (_logicalIds.isEmpty || chapter.$1.isEmpty || chapter.$2.isEmpty) {
      return null;
    }
    return logicalDownloadIdForMangaChapter(
      mangaId: chapter.$1,
      chapterId: chapter.$2,
    ).value;
  }

  DownloadItem? completed(MangaChapter chapter) {
    if (_chapters.isEmpty && _urls.isEmpty && _logicalIds.isEmpty) return null;
    final key = _chapterKey(chapter);
    var first = _chapters[key];
    final byUrl = _urls[chapter.url.trim()];
    if (byUrl != null && (first == null || byUrl < first)) first = byUrl;
    final logicalKey = _logicalKey(key);
    final byLogicalId = logicalKey == null ? null : _logicalIds[logicalKey];
    if (byLogicalId != null && (first == null || byLogicalId < first)) {
      first = byLogicalId;
    }
    return first == null ? null : _items[first];
  }

  bool alreadyPresent(MangaChapter chapter) {
    if (_chapters.isEmpty && _urls.isEmpty && _logicalIds.isEmpty) return false;
    final key = _chapterKey(chapter);
    if (_chapters.containsKey(key) || _urls.containsKey(chapter.url.trim())) {
      return true;
    }
    final logicalKey = _logicalKey(key);
    return logicalKey != null && _logicalIds.containsKey(logicalKey);
  }
}

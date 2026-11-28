import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MemoryStorage extends StorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

void main() {
  test('reading progress survives repository round trip', () async {
    final repository = MangaReadingRepository(_MemoryStorage());

    await repository.save(
      const MangaReadingProgress(
        mangaId: 'm1',
        chapterId: '12.5',
        pageIndex: 7,
        pageCount: 30,
        updatedAt: 100,
      ),
    );

    final restored = repository.get('m1', '12.5');
    expect(restored, isNotNull);
    expect(restored!.pageIndex, 7);
    expect(restored.pageCount, 30);
    expect(restored.isRead, isFalse);
  });

  test('interleaved Arabic titles keep the existing keys and live reads', () async {
    final storage = _MemoryStorage();
    var cloudRead = false;
    var changes = 0;
    final repository = MangaReadingRepository(
      storage,
      isCloudRead: (mangaId, chapterId) =>
          cloudRead && mangaId == 'مانغا أ' && chapterId == 'الفصل ١',
      onChanged: () => changes++,
    );
    const first = MangaReadingProgress(
      mangaId: '  مانغا أ\t',
      chapterId: ' الفصل ١ ',
      pageIndex: 1,
      pageCount: 10,
      updatedAt: 100,
      isBookmarked: true,
    );
    const firstKey =
        'manga_progress:43dab5526e801c6b38500854bb807650:8d1c614980bd37b6904f746d7354702e';
    const secondKey =
        'manga_progress:43dab5526e801c6b38500854bb807650:280e2a499543fd71a0d139f0abe90473';
    const otherTitleKey =
        'manga_progress:18b073b9d45fe4cff5b77d925d7d67ba:8d1c614980bd37b6904f746d7354702e';

    await repository.save(first);
    await repository.save(
      const MangaReadingProgress(
        mangaId: '  مانغا أ\t',
        chapterId: 'الفصل ٢',
        pageIndex: 3,
        pageCount: 10,
        updatedAt: 101,
      ),
    );
    await repository.save(
      const MangaReadingProgress(
        mangaId: 'مانغا ب',
        chapterId: 'الفصل ١',
        pageIndex: 7,
        pageCount: 10,
        updatedAt: 102,
      ),
    );
    expect(storage.values.keys, [firstKey, secondKey, otherTitleKey]);
    expect(repository.get('مانغا ب', 'الفصل ١')?.pageIndex, 7);

    final progress = repository.get('مانغا أ', 'الفصل ١')!;
    expect(progress.mangaId, 'مانغا أ');
    expect(progress.chapterId, 'الفصل ١');
    expect(progress.pageIndex, 1);
    expect(progress.isBookmarked, isTrue);
    expect(repository.get('مانغا أ', 'الفصل ٢')?.pageIndex, 3);

    final originalRow = storage.values[firstKey]!;
    storage.values[firstKey] = originalRow.replaceFirst(
      '"pageIndex":1',
      '"pageIndex":5',
    );
    expect(repository.get('مانغا أ', 'الفصل ١')?.pageIndex, 5);
    cloudRead = true;
    expect(repository.get('مانغا أ', 'الفصل ١')?.pageIndex, 9);
    expect(repository.get('مانغا أ', 'الفصل ١')?.isRead, isTrue);
    cloudRead = false;
    expect(repository.get('مانغا أ', 'الفصل ١')?.pageIndex, 5);
    expect(changes, 3);
  });

  test('toggleBookmark creates progress for an unseen chapter', () async {
    final repository = MangaReadingRepository(_MemoryStorage());

    expect(await repository.toggleBookmark('m1', 'c1'), isTrue);

    final restored = repository.get('m1', 'c1');
    expect(restored, isNotNull);
    expect(restored!.isBookmarked, isTrue);
    expect(restored.isRead, isFalse);
  });

  test('toggleRead creates a read row then toggles it unread', () async {
    final repository = MangaReadingRepository(_MemoryStorage());

    expect(await repository.toggleRead('m1', 'c1', pageCount: 12), isTrue);
    var restored = repository.get('m1', 'c1');
    expect(restored, isNotNull);
    expect(restored!.isRead, isTrue);
    expect(restored.pageIndex, 11);
    expect(restored.pageCount, 12);

    expect(await repository.toggleRead('m1', 'c1'), isFalse);
    restored = repository.get('m1', 'c1');
    expect(restored!.isRead, isFalse);
    expect(restored.pageIndex, 0);
    expect(restored.pageCount, 0);
  });

  test('markRead can create a read row for an unseen duplicate chapter', () async {
    final repository = MangaReadingRepository(_MemoryStorage());

    await repository.markRead('m1', 'duplicate', pageCount: 1);

    final restored = repository.get('m1', 'duplicate');
    expect(restored, isNotNull);
    expect(restored!.isRead, isTrue);
    expect(restored.pageIndex, 0);
    expect(restored.pageCount, 1);
  });

  test('markRead preserves identity and marks the last page', () async {
    final repository = MangaReadingRepository(_MemoryStorage());
    await repository.save(
      const MangaReadingProgress(
        mangaId: 'm1',
        chapterId: '13',
        pageIndex: 2,
        pageCount: 10,
        updatedAt: 100,
      ),
    );

    await repository.markRead('m1', '13');

    final restored = repository.get('m1', '13')!;
    expect(restored.isRead, isTrue);
    expect(restored.pageIndex, 9);
  });
  test('cloud read state is visible without duplicating local storage', () {
    final repository = MangaReadingRepository(
      _MemoryStorage(),
      isCloudRead: (mangaId, chapterId) =>
          mangaId == 'm1' && chapterId == 'remote-read',
    );

    final restored = repository.get('m1', 'remote-read');

    expect(restored, isNotNull);
    expect(restored!.isRead, isTrue);
    expect(restored.pageCount, 0);
  });

  test('batch read state syncs once and unread clears stale page progress', () async {
    final calls = <({String mangaId, List<String> ids, bool read})>[];
    final repository = MangaReadingRepository(
      _MemoryStorage(),
      syncReadStates: (mangaId, chapterIds, read) async {
        calls.add((mangaId: mangaId, ids: chapterIds.toList(), read: read));
      },
    );
    await repository.save(
      const MangaReadingProgress(
        mangaId: 'm1',
        chapterId: 'c1',
        pageIndex: 9,
        pageCount: 10,
        updatedAt: 100,
        isRead: true,
      ),
    );
    calls.clear();

    await repository.setReadStates(
      'm1',
      const <String>['c1', 'c2'],
      read: false,
    );

    expect(calls, hasLength(1));
    expect(calls.single.mangaId, 'm1');
    expect(calls.single.ids, <String>['c1', 'c2']);
    expect(calls.single.read, isFalse);
    final unread = repository.get('m1', 'c1')!;
    expect(unread.isRead, isFalse);
    expect(unread.pageCount, 0);
    expect(unread.pageIndex, 0);
  });

}

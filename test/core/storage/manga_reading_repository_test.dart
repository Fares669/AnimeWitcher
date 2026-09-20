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
}

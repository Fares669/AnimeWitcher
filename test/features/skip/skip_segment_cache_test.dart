import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/skip/data/skip_segment_cache.dart';
import 'package:animewitcher/features/skip/data/skip_service.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Storage extends StorageService {
  _Storage(this.value);

  String? value;
  int reads = 0;

  @override
  String? getString(String key) {
    expect(key, 'skip_segments_cache_json');
    reads++;
    return value;
  }

  @override
  Future<void> setString(String key, String? value) async {
    expect(key, 'skip_segments_cache_json');
    this.value = value;
  }
}

void main() {
  test('all fallback keys share one read; valid preferred keys win', () {
    final storage = _Storage('''
{"url:chosen":[{"type":"intro","start":20,"end":80}],
 "mal:123:1":[{"type":"recap","start":4.5,"end":9}]}
''');
    final cache = SkipSegmentCache(storage);
    expect(
      cache.readAny(['missing', 'url:chosen', 'mal:123:1']).single.type,
      SkipType.intro,
    );
    expect(storage.reads, 1);
    expect(cache.readAny(['another-miss', 'mal:123:1']).single.startTime, 4.5);
    expect(storage.reads, 2);
    expect(cache.readAny(const []), isEmpty);
    expect(storage.reads, 2);
  });

  test('corrupt timestamp records cannot block usable offline segments', () {
    final storage = _Storage('''
{"url:bad":[{"type":"intro","start":"wrong","end":80},
             {"type":"outro","start":99,"end":1},
             {"type":"intro","start":1,"end":1e400},null],
 "mal:123:1":[{"type":"outro","start":100,"end":110},
              {"type":"intro","start":0,"end":90},
              {"type":false,"start":93,"end":98}]}
''');
    final cache = SkipSegmentCache(storage);
    expect(cache.read('url:bad'), isEmpty);
    expect(
      cache.readAny(['url:bad', 'mal:123:1']).map((segment) => segment.type),
      [SkipType.intro, SkipType.outro],
    );
    expect(storage.reads, 2);
  });

  test('unchanged on-disk schema keeps URL and MAL keys in sync', () async {
    final storage = _Storage(null);
    final cache = SkipSegmentCache(storage);
    final keys = [
      SkipSegmentCache.keyForEpisodeUrl(' https://example.test/show '),
      SkipSegmentCache.keyForMal(42, 5),
    ];
    await cache.write(keys, [
      SkipSegment(startTime: 10, endTime: 72, type: SkipType.intro),
    ]);
    for (final key in keys) {
      final segment = cache.read(key).single;
      expect(segment.startTime, 10);
      expect(segment.endTime, 72);
      expect(segment.type, SkipType.intro);
    }
  });
}

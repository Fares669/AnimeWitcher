import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('schema v1 anime record migrates to generic media identity', () {
    final old = LogicalDownloadRecordV2.fromJson(<String, Object?>{
      'schemaVersion': 1,
      'logicalId': 'old-anime',
      'animeId': 'a1',
      'episodeKey': 'e2',
      'variantKey': 'sub',
      'generation': 1,
      'taskId': 't1',
      'intent': 'active',
      'destinationPath': '/tmp/a.mp4',
      'sourceDescriptor': <String, Object?>{},
      'updatedAtMillis': 1,
    });

    expect(old, isNotNull);
    expect(old!.mediaKind, DownloadMediaKind.videoEpisode);
    expect(old.mediaId, 'a1');
    expect(old.unitKey, 'e2');
    expect(old.animeId, 'a1');
    expect(old.episodeKey, 'e2');
  });

  test('schema v2 manga record round trips manga identity', () {
    final record = LogicalDownloadRecordV2.fromJson(<String, Object?>{
      'schemaVersion': 2,
      'logicalId': 'manga-record',
      'mediaKind': 'mangaChapter',
      'mediaId': 'm1',
      'unitKey': '12.5',
      'variantKey': 'pages',
      'generation': 1,
      'taskId': 't1',
      'intent': 'paused',
      'destinationPath': '/tmp/manga/m1/12.5',
      'sourceDescriptor': <String, Object?>{},
      'parallelChunks': 1,
      'updatedAtMillis': 2,
    });

    expect(record, isNotNull);
    expect(record!.mediaKind, DownloadMediaKind.mangaChapter);
    expect(record.mediaId, 'm1');
    expect(record.unitKey, '12.5');

    final encoded = record.toJson();
    expect(encoded['schemaVersion'], 2);
    expect(encoded['mediaKind'], 'mangaChapter');
    expect(encoded['mediaId'], 'm1');
    expect(encoded['unitKey'], '12.5');
    expect(encoded.containsKey('animeId'), isFalse);
    expect(encoded.containsKey('episodeKey'), isFalse);
  });
}

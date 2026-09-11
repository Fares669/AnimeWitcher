import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_logical_identity.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item() => MultimediaItem(
  title: 'Stable Show',
  url: 'https://catalog.example/show/42?ref=old',
  posterUrl: '',
  provider: 'AnimeWitcher',
  syncData: const {'malId': '4242'},
  contentType: MultimediaContentType.anime,
);

Episode _episode() => Episode(
  name: 'Episode 7',
  url: 'https://signed.example/old-token',
  season: 2,
  episode: 7,
  dubStatus: DubStatus.subbed,
);

void main() {
  group('DM-24 logical identity persistence', () {
    test('explicit persisted logical id outranks reconstructed metadata', () {
      final metadata = <String, dynamic>{
        'logicalId': 'download:v1|authoritative',
        'item': _item().toJson(),
        'episode': _episode().toJson(),
      };

      expect(
        logicalDownloadIdFromMetadata(metadata),
        'download:v1|authoritative',
      );
    });

    test('legacy presentation metadata migrates deterministically', () {
      final metadata = <String, dynamic>{
        'item': _item().toJson(),
        'episode': _episode().toJson(),
      };

      expect(
        logicalDownloadIdFromMetadata(metadata),
        DownloadLogicalIdentity.fromMedia(
          item: _item(),
          episode: _episode(),
        ).key,
      );
    });

    test('missing presentation identity never guesses from executor details', () {
      expect(
        logicalDownloadIdFromMetadata(<String, dynamic>{
          'trackingUrl': 'https://signed.example/file?token=x',
          'filePath': '/downloads/Episode 7.mp4',
          'taskSnapshot': <String, dynamic>{'taskId': 'attempt-7'},
        }),
        isNull,
      );
    });

    test('storage and start flow persist and consult logical identity', () {
      final storage = File('lib/core/storage/storage_service.dart').readAsStringSync();
      final service = File('lib/core/services/download_service.dart').readAsStringSync();

      final saveStart = storage.indexOf('Future<void> saveDownloadMetadata(');
      final patchStart = storage.indexOf('Future<void> patchDownloadMetadata(');
      final getStart = storage.indexOf('Future<Map<String, dynamic>?> getDownloadMetadata');
      expect(saveStart, greaterThanOrEqualTo(0));
      expect(patchStart, greaterThan(saveStart));
      expect(getStart, greaterThan(patchStart));
      final saveBody = storage.substring(saveStart, patchStart);
      final patchBody = storage.substring(patchStart, getStart);
      expect(saveBody, contains('String? logicalId'));
      expect(saveBody, contains("'logicalId': logicalId"));
      expect(patchBody, contains('String? logicalId'));
      expect(patchBody, contains("map['logicalId'] = logicalId"));

      final start = service.indexOf('Future<DownloadCommandOutcome> startDownloadOutcome({');
      final complete = service.indexOf('Future<List<TaskRecord>> _completeRecordsForEpisode(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(complete, greaterThan(start));
      final body = service.substring(start, complete);
      expect(body, contains('DownloadLogicalIdentity.fromMedia'));
      expect(body, contains('_jobStore.allForLogicalId(logicalId)'));
      expect(body, contains('logicalId: logicalId'));
      expect(body, contains('saveDownloadMetadata('));
    });
  });
}

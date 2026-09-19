import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('downloads presentation never writes executor lifecycle state directly', () {
    final source = File(
      'lib/features/library/presentation/downloads_provider.dart',
    ).readAsStringSync();

    expect(
      source,
      isNot(contains('FileDownloader().database.updateRecord(')),
      reason: 'presentation must not rewrite executor lifecycle state',
    );
    expect(
      source,
      isNot(contains('FileDownloader().database.deleteRecordWithId(')),
      reason: 'presentation must not delete executor database records',
    );
    expect(
      source,
      isNot(contains('deleteDownloadedEpisodeArtwork(')),
      reason: 'presentation should submit commands and project snapshots only',
    );
    expect(
      source,
      contains('downloadManagerV2Provider'),
      reason: 'presentation lifecycle commands must use the V2 manager',
    );
  });

  test('downloads presentation projects manager and store logical snapshots', () {
    final presentation = File(
      'lib/features/library/presentation/downloads_provider.dart',
    ).readAsStringSync();

    expect(
      presentation,
      isNot(contains('FileDownloader().database.allRecords(')),
      reason: 'raw executor inventory belongs behind the V2 gateway',
    );
    expect(
      presentation,
      contains('logicalDownloadStoreV2Provider'),
      reason: 'list refresh must load logical records from the V2 store',
    );
    expect(
      presentation,
      contains('getAllDownloadMetadata()'),
      reason: 'presentation may join app-owned display metadata to logical rows',
    );
    expect(
      presentation,
      contains('manager.snapshotFor(record.logicalId)'),
      reason: 'transport snapshots must come from the V2 manager',
    );
    expect(
      presentation,
      contains('logicalId: record.logicalId.value'),
      reason: 'rows must retain the logical V2 identity',
    );
  });
}

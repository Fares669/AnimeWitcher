import 'package:animewitcher/core/services/download_v2/download_artwork_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final record = LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: logicalDownloadIdFor(animeId: 'show://saved', episodeKey: 'episode://saved', variantKey: 'sub|1080p'),
    mediaId: 'show://saved', unitKey: 'episode://saved', variantKey: 'sub|1080p', generation: 1,
    taskId: 'exact-task', intent: DownloadUserIntent.active, destinationPath: 'saved.mp4',
    sourceDescriptor: const {}, updatedAtMillis: 1,
  );
  Map<String, dynamic> semantic({String? variant = 'sub|1080p'}) => {
    'item': {'url': 'show://saved', 'title': 'A renamed title'},
    'trackingUrl': 'episode://saved', if (variant != null) 'variantKey': variant,
  };

  test('an explicit exact logical ID authorizes only that record', () {
    expect(downloadArtworkMetadataMatchesRecordV2({'logicalId': record.logicalId.value}, record), isTrue);
    expect(downloadArtworkMetadataMatchesRecordV2({...semantic(), 'logicalId': 'another-variant'}, record), isFalse);
    expect(downloadArtworkMetadataMatchesRecordV2({...semantic(), 'logicalId': ''}, record), isFalse);
  });
  test('absent ID needs independently saved complete semantic variant', () {
    expect(downloadArtworkMetadataMatchesRecordV2(semantic(), record), isTrue);
    expect(downloadArtworkMetadataMatchesRecordV2(semantic(variant: null), record), isFalse);
    expect(downloadArtworkMetadataMatchesRecordV2(semantic(variant: 'sub|480p'), record), isFalse);
    expect(downloadArtworkMetadataMatchesRecordV2({...semantic(), 'trackingUrl': 'another-episode'}, record), isFalse);
    expect(downloadArtworkMetadataMatchesRecordV2({...semantic(), 'item': {'url': 'another-show', 'title': 'A renamed title'}}, record), isFalse);
  });
  test('semantic reconstruction preserves launcher TMDB then IMDb identity precedence', () {
    for (final media in [(id: '21', item: {'tmdbId': 21, 'imdbId': 'tt-other', 'url': 'show://other'}),
      (id: 'tt21', item: {'imdbId': 'tt21', 'url': 'show://other'})]) {
      final identified = record.copyWith(mediaId: media.id, logicalId: logicalDownloadIdFor(
        animeId: media.id, episodeKey: record.unitKey, variantKey: record.variantKey,
      ));
      expect(downloadArtworkMetadataMatchesRecordV2({...semantic(), 'item': media.item}, identified), isTrue);
    }
  });
}

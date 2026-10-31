import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/domain/stream_source_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

StreamResult source(String server, String? quality, String url) =>
    StreamResult(source: server, quality: quality, url: url);

void main() {
  test('common servers ignore quality but require a usable source URL', () {
    final common = commonBatchStreamServers([
      [
        source('PD', '1080p', 'pd-1080'),
        source('PD', '720p', 'pd-720'),
        source('MF', '720p', 'mf-720'),
        source('ST', '1080p', ''),
      ],
      [
        source('pd server', '480p', 'other-pd'),
        source('Mediafire', '1080p', 'other-mf'),
        source('ST', '1080p', 'other-st'),
      ],
    ]);
    expect(common.map((entry) => entry.url), ['pd-1080', 'mf-720']);
    expect(commonBatchStreamServers([]), isEmpty);
  });

  test(
    'batch options require the same server AND quality in every episode',
    () {
      final first = [
        source('PD', '720p', 'pd-720'),
        source('PD', '1080p', 'pd-1080'),
        source('MF', '720p', 'mf-720'),
      ];
      final second = [
        source('Mediafire', '720p', 'other-mf-720'),
        source('pd server', '1080p', 'other-pd-1080'),
      ];
      final common = commonBatchStreamSources([first, second]);
      expect(common.map((e) => e.url), ['pd-1080', 'mf-720']);
    },
  );

  test(
    'batch source match is normalized and not confused by missing quality',
    () {
      final all = commonBatchStreamSources([
        [source('PD', 'HD', 'a'), source('PD', '1080p', 'b')],
        [source('pd', '720p', 'c'), source('PD', '480p', 'd')],
      ]);
      expect(all.map((e) => e.url), ['a']);
      expect(commonBatchStreamSources([]), isEmpty);
      expect(
        commonBatchStreamSources([
          [],
          [source('PD', '720p', 'a')],
        ]),
        isEmpty,
      );
    },
  );

  test('batch options exclude sources whose quality is missing', () {
    final common = commonBatchStreamSources([
      [
        source('PD', null, 'missing-null'),
        source('MF', '', 'missing-empty'),
        source('ST', '720p', 'known'),
      ],
      [
        source('PD', '', 'other-missing-empty'),
        source('MF', null, 'other-missing-null'),
        source('ST', 'HD', 'other-known'),
      ],
    ]);

    expect(common.map((entry) => entry.url), ['known']);
  });
}

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/domain/stream_source_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'stream order prefers first case-insensitive priority and keeps ties',
    () {
      const sources = [
        StreamResult(url: 'other', source: 'Other', quality: 'Unlisted'),
        StreamResult(url: 'mq', source: 'MF', quality: '4k'),
        StreamResult(url: 'pq', source: 'PD', quality: '1080'),
        StreamResult(url: 'ma', source: 'MediaFire', quality: 'AUTO'),
        StreamResult(url: 'pa1', source: 'pd2', quality: 'multi'),
        StreamResult(url: 'pa2', source: 'PixelDrain', quality: 'متعدد'),
      ];
      final ordered = orderStreamSourcesByPreference(
        sources,
        qualityPriority: const ['متعدد', 'anything', 'متعدد'],
        serverPriority: const ['pd', 'mf', 'PD'],
      );
      expect(
        ordered,
        equals([
          sources[4],
          sources[5],
          sources[3],
          sources[1],
          sources[2],
          sources[0],
        ]),
      );
      expect(() => ordered.clear(), throwsUnsupportedError);
    },
  );
}

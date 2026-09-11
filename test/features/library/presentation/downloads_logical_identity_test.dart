import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DM-24 downloads UI logical identity', () {
    test('DownloadItem carries the canonical logical id', () {
      final source = File(
        'lib/features/library/presentation/downloads_provider.dart',
      ).readAsStringSync();
      final classStart = source.indexOf('class DownloadItem {');
      final classEnd = source.indexOf('bool downloadsPointAtSameTarget(', classStart);
      expect(classStart, greaterThanOrEqualTo(0));
      expect(classEnd, greaterThan(classStart));
      final body = source.substring(classStart, classEnd);

      expect(body, contains('final String? logicalId;'));
      expect(body, contains('this.logicalId'));
    });

    test('known different logical ids never fall through to URL/file matching', () {
      final source = File(
        'lib/features/library/presentation/downloads_provider.dart',
      ).readAsStringSync();
      final start = source.indexOf('bool downloadsPointAtSameTarget(');
      final end = source.indexOf('int _statusRank(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(body, contains('a.logicalId'));
      expect(body, contains('b.logicalId'));
      expect(body, contains('return a.logicalId == b.logicalId'));
      expect(
        body.indexOf('return a.logicalId == b.logicalId'),
        lessThan(body.indexOf('downloadTrackingUrl')),
      );
    });

    test('grouping uses legacy URL/file keys only when logical id is absent', () {
      final source = File(
        'lib/features/library/presentation/downloads_provider.dart',
      ).readAsStringSync();
      final start = source.indexOf('List<List<DownloadItem>> groupDownloadsByEpisodeOrFile(');
      final end = source.indexOf('class CollapsedDownloads', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(body, contains('byLogicalId'));
      expect(body, contains('if (logicalId != null && logicalId.isNotEmpty)'));
      expect(body, contains('continue;'));
    });
  });
}

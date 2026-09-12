import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/core/services/persistent_parallel_download.dart')
      .readAsStringSync();

  test('exact-size multipart adoption still requires writer settlement', () {
    final start = source.indexOf('Future<bool> _adoptExactSizePart(');
    final end = source.indexOf('Future<void> _afterAdoptedPart(', start);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing adoption seam');
    expect(end, greaterThan(start), reason: 'missing adoption boundary');
    final body = source.substring(start, end);

    final settleStart = body.indexOf('if (settleNativeOwner) {');
    final verifyAgain = body.indexOf(
      'if (!await file.exists() || await file.length() != part.size) return false;',
      settleStart,
    );
    expect(settleStart, greaterThanOrEqualTo(0));
    expect(verifyAgain, greaterThan(settleStart));
    final settlement = body.substring(settleStart, verifyAgain);

    expect(settlement, contains('await pausePart(part.task);'));
    expect(
      settlement,
      contains('return false;'),
      reason:
          'bytesVerified must not imply ownerSettled when the native pause/ownership acknowledgement fails',
    );
  });
}

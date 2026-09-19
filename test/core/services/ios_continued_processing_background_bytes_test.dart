import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native background live task advances from child-byte delta over the latest Dart parent snapshot',
    () {
      final source = File(
        'ios/Runner/DownloadContinuedProcessingManager.swift',
      ).readAsStringSync().replaceAll('\r\n', '\n');

      expect(source, contains('nativeAggregateBaselineBytes'));
      expect(source, contains('nativeParentBaselineBytes'));
      expect(source, contains('resetNativeAggregateBaseline()'));
      expect(
        source,
        contains('let aggregateDelta = transferredBytes - nativeAggregateBaselineBytes'),
      );
      expect(
        source,
        contains('nativeParentBaselineBytes + max(aggregateDelta, 0)'),
        reason:
            'child aggregate bytes are not whole-file bytes after a background '
            'handoff; live-task progress must add their delta to the latest '
            'parent byte checkpoint rather than freeze until the subtotal catches up',
      );
      expect(
        source,
        contains('preserveNativeAggregateBaseline: true'),
        reason:
            'native updates must not reset their own background baseline every tick',
      );
    },
  );
}

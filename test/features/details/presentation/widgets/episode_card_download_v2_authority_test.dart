import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('episode card reads V2 download presentation instead of V1 state', () {
    final source = File(
      'lib/features/details/presentation/widgets/episode_card.dart',
    ).readAsStringSync();

    expect(
      source,
      isNot(contains('core/services/download_service.dart')),
      reason: 'V2 downloads never publish into the legacy active/progress maps.',
    );
    expect(source, isNot(contains('activeDownloadsProvider')));
    expect(
      source,
      contains('library/presentation/download_progress_v2_provider.dart'),
    );
    expect(source, contains('library/presentation/downloads_provider.dart'));
  });
}

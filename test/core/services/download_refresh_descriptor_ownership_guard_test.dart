import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DM-31 keeps refresh descriptor lifecycle inside DownloadService', () {
    final launcher = File(
      'lib/features/details/presentation/download_launcher.dart',
    ).readAsStringSync();
    final service = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final store = File('lib/core/services/download_url_refresh.dart')
        .readAsStringSync();

    expect(launcher, isNot(contains('await refreshStore.save(')));
    expect(launcher, isNot(contains('await refreshStore.remove(resolveUrl)')));
    expect(
      launcher,
      contains('refreshDescriptor: DownloadUrlRefreshDescriptor('),
    );

    expect(
      service,
      contains('DownloadUrlRefreshDescriptor? refreshDescriptor,'),
    );
    expect(service, contains('_commitRefreshDescriptorForGeneration('));

    expect(store, contains('required this.generation'));
    expect(store, contains('Future<bool> removeForGeneration('));
    expect(store, contains('descriptor.generation != generation'));
  });
}

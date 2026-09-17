import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _EmptyDownloadsNotifier extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const <DownloadItem>[];
}

void main() {
  test('does not construct the V2 manager for an empty projection', () {
    final container = ProviderContainer(
      overrides: [
        downloadsProvider.overrideWith(() => _EmptyDownloadsNotifier()),
        downloadManagerV2Provider.overrideWith((ref) {
          throw StateError('V2 manager must not be read for an empty projection');
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(downloadProgressProvider), isEmpty);
  });
}

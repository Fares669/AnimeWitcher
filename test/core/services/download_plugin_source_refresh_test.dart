import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'compatible changed URL with partial bytes uses verified Range fallback',
    () {
      expect(
        planRefreshedTransferResume(
          resourceCompatible: true,
          hasPartialBytes: true,
          pluginCanResumeChangedSource: false,
        ),
        RefreshedTransferResumeMode.verifiedRangeFallback,
      );
    },
  );

  test('compatible changed URL uses plugin when plugin can resume it', () {
    expect(
      planRefreshedTransferResume(
        resourceCompatible: true,
        hasPartialBytes: true,
        pluginCanResumeChangedSource: true,
      ),
      RefreshedTransferResumeMode.pluginResume,
    );
  });

  test('incompatible resource with durable partial bytes fails closed', () {
    expect(
      planRefreshedTransferResume(
        resourceCompatible: false,
        hasPartialBytes: true,
        pluginCanResumeChangedSource: true,
      ),
      RefreshedTransferResumeMode.incompatibleResource,
    );
  });

  test('zero partial bytes can safely fresh-start through plugin', () {
    expect(
      planRefreshedTransferResume(
        resourceCompatible: false,
        hasPartialBytes: false,
        pluginCanResumeChangedSource: false,
      ),
      RefreshedTransferResumeMode.pluginResume,
    );
  });
}

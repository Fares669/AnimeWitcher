import 'package:flutter_test/flutter_test.dart';

import 'package:animewitcher/features/player/data/mpv_renderer_policy.dart';

void main() {
  test('declares gpu-next as primary and gpu as fallback', () {
    expect(MpvRendererPolicy.primary, 'gpu-next');
    expect(MpvRendererPolicy.fallback, 'gpu');
    expect(MpvRendererPolicy.androidVideoOutput, 'gpu-next,gpu');
  });

  test('uses the explicit priority list on Android', () {
    expect(
      MpvRendererPolicy.outputForPlatform(isAndroid: true),
      'gpu-next,gpu',
    );
  });

  test('keeps media_kit render API and Apple Metal output intact', () {
    expect(
      MpvRendererPolicy.outputForPlatform(isAndroid: false),
      'libmpv',
    );
  });

  test('exposes an explicit fallback for direct-VO diagnostics', () {
    expect(
      MpvRendererPolicy.diagnosticOutput(useFallback: false),
      'gpu-next',
    );
    expect(
      MpvRendererPolicy.diagnosticOutput(useFallback: true),
      'gpu',
    );
  });
}

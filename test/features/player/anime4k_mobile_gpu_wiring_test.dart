import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings expose Anime4K on Android and iOS', () {
    final source = File(
      'lib/features/settings/presentation/settings_screen.dart',
    ).readAsStringSync();

    expect(source, contains('Platform.isAndroid'));
    expect(source, contains('Platform.isIOS'));
  });

  test('Android player explicitly uses mpv GPU output for Anime4K', () {
    final source = File('lib/features/player/presentation/player_screen.dart')
        .readAsStringSync();

    expect(source, contains("'player_anime4k_enabled'"));
    expect(source, contains("'player_anime4k_mode'"));
    expect(source, contains("Platform.isAndroid ? 'gpu' : 'libmpv'"));
  });

  test('player verifies a real mpv GPU renderer before applying shaders', () {
    final source = File(
      'lib/features/player/presentation/player_controller.dart',
    ).readAsStringSync();

    expect(source, contains("getProperty('current-vo')"));
    expect(source, contains("getProperty('gpu-dumb-mode')"));
    expect(source, contains('anime4kGpuRendererSupportsShaders'));
    expect(source, contains("getProperty('glsl-shaders')"));
  });

  test('sample preview validates the same GPU shader path', () {
    final source = File(
      'lib/features/player/presentation/widgets/anime4k_sample_preview.dart',
    ).readAsStringSync();

    expect(source, contains("getProperty('current-vo')"));
    expect(source, contains("getProperty('gpu-dumb-mode')"));
    expect(source, contains('anime4kGpuRendererSupportsShaders'));
  });
}

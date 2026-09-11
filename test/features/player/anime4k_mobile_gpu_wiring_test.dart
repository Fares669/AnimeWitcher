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

  test('player checks gpu-dumb-mode only after asking mpv to load shaders', () {
    final source = File(
      'lib/features/player/presentation/player_controller.dart',
    ).readAsStringSync();

    final apply = source.indexOf("setProperty('glsl-shaders', pipeline.value)");
    final dumbMode = source.indexOf("getProperty('gpu-dumb-mode')");
    expect(apply, greaterThanOrEqualTo(0));
    expect(dumbMode, greaterThan(apply));
  });

  test('sample preview validates the same GPU shader path', () {
    final source = File(
      'lib/features/player/presentation/widgets/anime4k_sample_preview.dart',
    ).readAsStringSync();

    expect(source, contains("getProperty('current-vo')"));
    expect(source, contains("getProperty('gpu-dumb-mode')"));
    expect(source, contains('anime4kGpuRendererSupportsShaders'));
  });

  test('sample preview checks dumb mode after loading the shader chain', () {
    final source = File(
      'lib/features/player/presentation/widgets/anime4k_sample_preview.dart',
    ).readAsStringSync();

    final apply = source.indexOf("setProperty('glsl-shaders', pipeline.value)");
    final dumbMode = source.indexOf("getProperty('gpu-dumb-mode')");
    expect(apply, greaterThanOrEqualTo(0));
    expect(dumbMode, greaterThan(apply));
  });
}

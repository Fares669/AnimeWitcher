import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Apple media_kit render disables redundant mpv target-time blocking', () {
    final pacingPatch = File('scripts/anime4k_mpv_pacing_patch.rb');
    expect(
      pacingPatch.existsSync(),
      isTrue,
      reason:
          'Apple rendering needs an explicit non-blocking mpv pacing patch before Anime4K Metal work.',
    );
    if (!pacingPatch.existsSync()) return;

    final source = pacingPatch.readAsStringSync();
    expect(source, contains('MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME'));
    expect(source, contains('anime4kBlockForTargetTime: CInt = 0'));
    expect(source, contains('AnimeWitcherNonBlockingMPVRender'));

    for (final podfilePath in <String>['ios/Podfile', 'macos/Podfile']) {
      final podfile = File(podfilePath).readAsStringSync();
      expect(
        podfile,
        contains("require_relative '../scripts/anime4k_mpv_pacing_patch'"),
        reason: '$podfilePath must load the Apple mpv pacing integration.',
      );
      expect(
        podfile,
        contains('patch_anime4k_mpv_render_pacing('),
        reason: '$podfilePath must patch media_kit before CocoaPods compiles it.',
      );
    }
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the player controls answer a tap at once', () {
    // A double-tap recognizer anywhere above a button holds its press for
    // the double-tap timeout, about a third of a second, to see whether a
    // second tap follows. The controls tell double taps apart by hand.
    final source = File(
      'lib/features/player/presentation/widgets/animewitcher_player_controls.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('onDoubleTap:')));
    expect(source, contains('_isSecondTap('));
  });

  test('watched episode thumbnail follows the active theme accent', () {
    final source = File(
      'lib/features/player/presentation/widgets/player_side_panel.dart',
    ).readAsStringSync();
    final start = source.indexOf('class _EpisodeThumbnail');
    final end = source.indexOf('class _ThumbPlaceholder', start);
    final thumbnail = source.substring(start, end);

    expect(thumbnail, contains('Theme.of(context).colorScheme.primary'));
    expect(thumbnail, contains('if (isWatched || hasProgress)'));
    expect(thumbnail, contains('value: isWatched ? 1.0 : progress'));
  });

  test('the bottom bar paints its own scrim', () {
    final source = File(
      'lib/features/player/presentation/widgets/player_control_components.dart',
    ).readAsStringSync();
    expect(source, contains('HotstarPlayerStyle.bottomGradient'));
    expect(source, contains('HotstarPlayerStyle.glyphShadows'));
  });
}

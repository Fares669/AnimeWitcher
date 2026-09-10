import 'package:animewitcher/features/player/presentation/player_shortcuts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('number keys', () {
    test('jump to their tenth of the episode', () {
      expect(seekFractionForKey(LogicalKeyboardKey.digit0), 0.0);
      expect(seekFractionForKey(LogicalKeyboardKey.digit1), 0.1);
      expect(seekFractionForKey(LogicalKeyboardKey.digit5), 0.5);
      expect(seekFractionForKey(LogicalKeyboardKey.digit9), 0.9);
    });

    test('the numpad does the same', () {
      expect(seekFractionForKey(LogicalKeyboardKey.numpad0), 0.0);
      expect(seekFractionForKey(LogicalKeyboardKey.numpad7), 0.7);
    });

    test('nothing else is a seek', () {
      for (final key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.keyK,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.f5,
      ]) {
        expect(seekFractionForKey(key), isNull, reason: key.debugName);
      }
    });
  });

  group('speed stepping', () {
    double up(double from, {double max = 2.0}) =>
        steppedPlaybackSpeed(from, faster: true, maxSpeed: max);
    double down(double from, {double max = 2.0}) =>
        steppedPlaybackSpeed(from, faster: false, maxSpeed: max);

    test('moves a quarter at a time', () {
      expect(up(1.0), 1.25);
      expect(up(1.25), 1.5);
      expect(down(1.0), 0.75);
      expect(down(0.75), 0.5);
    });

    test('a speed left off the grid by the slider snaps the way it is going', () {
      expect(up(1.35), 1.5);
      expect(down(1.35), 1.25);
      expect(up(0.3), 0.5);
      expect(down(0.3), 0.25);
    });

    test('stops at the ends instead of wrapping', () {
      expect(up(2.0), 2.0);
      expect(up(1.9), 2.0);
      expect(down(minPlaybackSpeed), minPlaybackSpeed);
      expect(down(0.3), 0.25);
    });

    test('a source that cannot be sped up is left alone', () {
      // maxPlaybackSpeed below the floor means the engine will not vary
      // speed at all; both keys must then be inert rather than snapping the
      // playback to some other value.
      expect(steppedPlaybackSpeed(1.0, faster: true, maxSpeed: 0.0), 1.0);
      expect(steppedPlaybackSpeed(1.0, faster: false, maxSpeed: 0.0), 1.0);
    });

    test('never exceeds three, whatever the engine claims', () {
      expect(up(2.9, max: 10.0), 3.0);
      expect(up(3.0, max: 10.0), 3.0);
    });

    test('repeated steps do not drift', () {
      var speed = 1.0;
      for (var i = 0; i < 4; i++) {
        speed = steppedPlaybackSpeed(speed, faster: true, maxSpeed: 3.0);
      }
      expect(speed, 2.0);
      for (var i = 0; i < 7; i++) {
        speed = steppedPlaybackSpeed(speed, faster: false, maxSpeed: 3.0);
      }
      expect(speed, 0.25);
    });
  });

  group('speed label', () {
    test('drops the zeros the number does not need', () {
      expect(playbackSpeedLabel(1.0), '1x');
      expect(playbackSpeedLabel(2.0), '2x');
      expect(playbackSpeedLabel(1.5), '1.5x');
      expect(playbackSpeedLabel(1.25), '1.25x');
      expect(playbackSpeedLabel(0.25), '0.25x');
      expect(playbackSpeedLabel(0.5), '0.5x');
    });
  });
}

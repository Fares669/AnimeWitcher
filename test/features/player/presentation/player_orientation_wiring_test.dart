import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final screen = File('lib/features/player/presentation/player_screen.dart')
      .readAsStringSync();
  final controls = File(
    'lib/features/player/presentation/widgets/animewitcher_player_controls.dart',
  ).readAsStringSync();

  test('the route owns orientation restoration, not disposable controls', () {
    expect(controls.contains('SystemChrome.setPreferredOrientations'), isFalse);
    expect(screen, contains('platformService: _platformService'));
    expect(controls, contains('_platformService = widget.platformService'));
  });

  test('back restores orientation before popping; disposal is a fallback', () {
    final back = screen.substring(
      screen.indexOf('Future<void> _handleBack()'),
      screen.indexOf('void _publishPersistentPlayerHeader'),
    );
    final restore = back.indexOf('await orientationRestored');
    expect(
      back.indexOf('_restoreOrientation()'),
      lessThan(back.indexOf('await stopPlayerBeforeExit')),
    );
    expect(restore, greaterThanOrEqualTo(0));
    expect(restore, lessThan(back.indexOf('context.pop()')));
    final dispose = screen.substring(
      screen.indexOf('void dispose()'),
      screen.indexOf('bool _isPlayActivationKey'),
    );
    expect(dispose, contains('_restoreOrientation().then('));
    expect(dispose, contains('applyImmersiveFullScreen(false)'));
  });
}

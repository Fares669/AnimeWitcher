import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy More entries are removed without reordering other tabs', () {
    final order = normalizeTaskbarOrder([
      'settings',
      'downloads',
      'home',
      'downloads',
    ]);
    expect(order.take(2), [
      TaskbarDestination.downloads,
      TaskbarDestination.home,
    ]);
    expect(order, isNot(contains(TaskbarDestination.settings)));
    expect(order.toSet().length, order.length);
    expect(defaultTaskbarOrderIds, isNot(contains('settings')));
  });

  test('More is never visible or offered as the initial tab', () {
    expect(
      visibleTaskbarDestinations(['settings', 'search'], {}),
      isNot(contains(TaskbarDestination.settings)),
    );
    expect(
      resolveInitialTaskbarRoute('/settings', ['search', 'settings'], {}),
      '/search',
    );
  });

  test('hiding every tab keeps Home reachable instead of an empty bar', () {
    final hidden = TaskbarDestination.values.map((value) => value.id).toSet();
    expect(visibleTaskbarDestinations([], hidden), [TaskbarDestination.home]);
    expect(resolveInitialTaskbarRoute('/settings', [], hidden), '/home');
    expect(normalizeHiddenTaskbarItems(hidden), isNot(contains('settings')));
  });

  test('hidden preferred tabs fall back to the first visible tab', () {
    expect(
      resolveInitialTaskbarRoute('/downloads', ['search', 'home'], {'downloads'}),
      '/search',
    );
  });
}

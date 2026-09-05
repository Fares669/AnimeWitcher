import 'package:animewitcher/features/search/presentation/widgets/search_action_buttons.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_glass_surface.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The phone's search bar is a field and a sort/filter group sharing one line,
/// and the group rides in an `AppBar` slot rather than beside the field in a
/// row. That slot hands its child a tight height, and a `SizedBox` cannot be
/// smaller than what it is given — which is how the group came to stand at the
/// toolbar's own 56 next to a shorter field.
void main() {
  testWidgets('the button group keeps its height inside an AppBar slot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final fieldKey = UniqueKey();

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              titleSpacing: 12,
              centerTitle: true,
              leadingWidth:
                  SearchActionButtons.groupWidthForHeight(
                    SearchGlassSurface.height,
                  ) +
                  10,
              leading: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: SearchActionButtons(
                  sortValue: 'default',
                  sortItems: const <AppleNativeMenuItem>[
                    AppleNativeMenuItem(value: 'default', label: 'Default'),
                  ],
                  onSortSelected: (_) {},
                  onFilterPressed: () {},
                  sortTooltip: 'Sort',
                  filterTooltip: 'Filters',
                  sortIcon: Icons.swap_vert_rounded,
                  sortSystemImage: 'arrow.up.arrow.down',
                ),
              ),
              title: SearchGlassSurface(
                key: fieldKey,
                child: const TextField(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final field = tester.getRect(find.byKey(fieldKey));
    final group = tester.getRect(
      find.byKey(const ValueKey('search-action-capsule')),
    );

    expect(group.height, SearchGlassSurface.height);
    expect(field.height, group.height);
    // On one line, centred against each other rather than one standing taller.
    expect(field.center.dy, closeTo(group.center.dy, 0.5));
    // 48 is the smallest a thumb should be asked to hit.
    expect(group.height, greaterThanOrEqualTo(48));
  });
}

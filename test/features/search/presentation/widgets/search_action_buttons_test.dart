import 'package:animewitcher/features/search/presentation/widgets/search_action_buttons.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_glass_surface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('iOS draws sort and filter as plain buttons, no native glass', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: SearchActionButtons(
                sortValue: 'name_asc',
                sortItems: const <AppleNativeMenuItem>[
                  AppleNativeMenuItem(
                    value: 'name_asc',
                    label: 'Name',
                    systemImage: 'animewitcher.abc',
                  ),
                ],
                onSortSelected: (_) {},
                onFilterPressed: () {},
                sortTooltip: 'Sort',
                filterTooltip: 'Filters',
                sortIcon: Icons.sort_by_alpha,
                sortSystemImage: 'animewitcher.abc',
                tintColor: Colors.purple,
                filterCount: 3,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The native glass is retired: iOS draws what every platform does.
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byTooltip('Sort'), findsOneWidget);
      expect(find.byTooltip('Filters'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      );
    }
  });

  testWidgets('search and actions align with a theme-colored count badge', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var count = 2;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
        home: Scaffold(
          appBar: AppBar(
            title: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Row(
                  children: [
                    Expanded(
                      child: SearchGlassSurface(
                        key: const ValueKey('search-field-glass'),
                        child: TextField(controller: controller),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SearchActionButtons(
                      sortValue: 'default',
                      sortItems: const [AppleNativeMenuItem(value: 'default', label: 'Default')],
                      onSortSelected: (_) {},
                      onFilterPressed: () {},
                      sortTooltip: 'Sort',
                      filterTooltip: 'Filters',
                      sortIcon: Icons.arrow_upward_rounded,
                      sortSystemImage: 'arrow.up',
                      filterCount: count,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    final field = tester.getRect(find.byKey(const ValueKey('search-field-glass')));
    final actions = tester.getRect(find.byKey(const ValueKey('search-action-capsule')));
    expect(field.height, SearchGlassSurface.height);
    expect(actions.height, field.height);
    expect(actions.top, field.top);
    expect(actions.left - field.right, 10);
    // The field is a plain filled pill now, like the library's; only the
    // action capsule is glass.
    expect(find.byType(AppleLiquidGlassSurface), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    final badgeBox = tester.widget<Container>(find.descendant(
      of: find.byType(SearchFilterBadge), matching: find.byType(Container),
    ));
    final decoration = badgeBox.decoration! as BoxDecoration;
    expect(decoration.color, theme.colorScheme.primary);
    expect(decoration.shape, BoxShape.circle);
    final icon = tester.widget<Icon>(find.byIcon(Icons.arrow_upward_rounded));
    final theme = Theme.of(tester.element(find.byType(SearchActionButtons)));
    expect(icon.color, theme.colorScheme.primary);

    await tester.enterText(find.byType(TextField), 'Anime');
    expect(controller.text, 'Anime');
    update(() => count = 0);
    await tester.pump();
    expect(find.byType(SearchFilterBadge), findsNothing);
    expect(tester.getRect(find.byKey(const ValueKey('search-action-capsule'))), actions);
  });

  testWidgets('filter hitbox stays aligned with the icon in an RTL AppBar', (
    tester,
  ) async {
    var filterPresses = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(
              leadingWidth: 106,
              leading: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: SearchActionButtons(
                  sortValue: 'default',
                  sortItems: const <AppleNativeMenuItem>[
                    AppleNativeMenuItem(value: 'default', label: 'Default'),
                  ],
                  onSortSelected: (_) {},
                  onFilterPressed: () => filterPresses += 1,
                  sortTooltip: 'Sort',
                  filterTooltip: 'Filters',
                  sortIcon: Icons.swap_vert_rounded,
                  sortSystemImage: 'arrow.up.arrow.down',
                  height: 48,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    final groupRect = tester.getRect(find.byKey(const ValueKey('search-action-capsule')));
    final filterIconRect = tester.getRect(find.byIcon(Icons.tune_rounded));

    // Tapping the pixels that paint the icon must activate the filter itself.
    await tester.tapAt(filterIconRect.center);
    await tester.pump();
    expect(filterPresses, 1);

    // The entire right-hand 48px filter slot is intentionally tappable too.
    await tester.tapAt(Offset(groupRect.right - 2, groupRect.center.dy));
    await tester.pump();
    expect(filterPresses, 2);

    // Include all corners of the AppBar slot, outside the small painted glyph.
    for (final point in [
      Offset(groupRect.right - 47, groupRect.top + 1),
      Offset(groupRect.right - 1, groupRect.top + 1),
      Offset(groupRect.right - 47, groupRect.bottom - 1),
      Offset(groupRect.right - 1, groupRect.bottom - 1),
    ]) {
      await tester.tapAt(point);
      await tester.pump();
    }
    expect(filterPresses, 6);
  });

  testWidgets('alphabetical orders are spelled out in the sort menu', (
    tester,
  ) async {
    var picked = '';

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(
              leading: SearchActionButtons(
                sortValue: 'favorites',
                sortItems: const <AppleNativeMenuItem>[
                  AppleNativeMenuItem(
                    value: 'favorites',
                    label: 'Most favorited',
                    systemImage: 'star.fill',
                  ),
                  AppleNativeMenuItem(
                    value: 'name_asc',
                    label: 'Name A to Z',
                    systemImage: 'animewitcher.abc',
                  ),
                  AppleNativeMenuItem(
                    value: 'name_desc',
                    label: 'Name Z to A',
                    systemImage: 'animewitcher.zyx',
                  ),
                ],
                onSortSelected: (value) => picked = value,
                onFilterPressed: () {},
                sortTooltip: 'Sort',
                filterTooltip: 'Filters',
                sortIcon: Icons.swap_vert_rounded,
                sortSystemImage: 'star.fill',
                height: 48,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();

    // The two alphabetical orders read as letters rather than as an icon.
    expect(find.text('ABC'), findsOneWidget);
    expect(find.text('ZYX'), findsOneWidget);

    // And the menu still reports what was chosen, which it does by hand now
    // that the rows live inside one disabled popup item.
    await tester.tap(find.text('Name Z to A'));
    await tester.pumpAndSettle();
    expect(picked, 'name_desc');
  });

  testWidgets('a drawn sort mark is as bright as a spelled one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            leading: SearchActionButtons(
              sortValue: 'favorites',
              sortItems: const <AppleNativeMenuItem>[
                AppleNativeMenuItem(
                  value: 'favorites',
                  label: 'Most favorited',
                  systemImage: 'star.fill',
                ),
                AppleNativeMenuItem(
                  value: 'date_asc',
                  label: 'Oldest first',
                  icon: Icons.arrow_upward_rounded,
                  systemImage: 'arrow.up',
                ),
                AppleNativeMenuItem(
                  value: 'name_asc',
                  label: 'Name A to Z',
                  systemImage: 'animewitcher.abc',
                ),
              ],
              onSortSelected: (_) {},
              onFilterPressed: () {},
              sortTooltip: 'Sort',
              filterTooltip: 'Filters',
              sortIcon: Icons.swap_vert_rounded,
              sortSystemImage: 'star.fill',
              height: 48,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();

    // The panel rides inside a disabled popup item, which dims the icons
    // around it. `Icon` folds that opacity into its colour and `Text` does
    // not, so an arrow row would paint at half the alpha of the ABC beside
    // it while both were handed the very same colour.
    final arrow = tester.element(find.byIcon(Icons.arrow_upward_rounded));
    expect(IconTheme.of(arrow).opacity ?? 1.0, 1.0);
  });
}

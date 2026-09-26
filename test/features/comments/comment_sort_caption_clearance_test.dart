import 'dart:io';

import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/utils/window_controls_inset.dart';
import 'package:animewitcher/features/comments/presentation/widgets/animewitcher_comment_sort_control.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The three comment headers all hold themselves left to right and take this
  // one list for their actions, so the corner it lands in is the corner the
  // window paints minimise, maximise and close over.
  Widget header() => MaterialApp(
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: AppBar(
              automaticallyImplyLeading: false,
              titleSpacing: 16,
              title: const Align(
                alignment: Alignment.centerRight,
                child: Text('التعليقات'),
              ),
              actions: AnimeWitcherCommentSortControl.appBarActions(
                tooltip: 'ترتيب التعليقات',
                selectedValue: 'commentsDefault',
                items: AnimeWitcherCommentSortControl.menuItems(true),
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('the sort control stays out of the caption buttons corner', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(header());
    await tester.pump();

    final sort = tester.getRect(find.byKey(kAnimeWitcherCommentSortControlKey));
    final windowRight = tester.getSize(find.byType(MaterialApp)).width;

    expect(
      windowRight - sort.right,
      greaterThanOrEqualTo(windowControlsTrailingInset),
      reason: 'the sort button sat under the window controls',
    );
  });

  testWidgets('and takes the whole corner back where there are none', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // A phone, where nothing is painted over that corner: the room must not
    // be reserved, or the control floats away from the edge for no reason.
    debugWindowControlsInsetOverride = 0;
    addTearDown(() => debugWindowControlsInsetOverride = null);

    await tester.pumpWidget(header());
    await tester.pump();

    final sort = tester.getRect(find.byKey(kAnimeWitcherCommentSortControlKey));
    final windowRight = tester.getSize(find.byType(MaterialApp)).width;

    expect(windowRight - sort.right, lessThan(24));
  });

  testWidgets(
    'persistent comment sort is a compact icon aligned with the back button',
    (tester) async {
      List<AppleLiquidGlassToolbarButton>? buttons;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              buttons = AnimeWitcherCommentSortControl.persistentButtons(
                context: context,
                isArabic: true,
                tooltip: 'ترتيب التعليقات',
                sort: AnimeWitcherCommentSort.newest,
                onSelected: (_) {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(buttons, isNotNull);
      expect(buttons!.single.width, AnimeWitcherCommentSortControl.size);
      expect(buttons!.single.title, isNull);
      expect(
        AnimeWitcherCommentSortControl.persistentTrailingInset,
        8,
        reason: 'the sort button should mirror the 8pt back-button edge inset',
      );
      expect(
        AnimeWitcherCommentSortControl.persistentTitleClearance,
        lessThan(92),
        reason: 'the title should move right with the compact sort control',
      );
    },
  );

  testWidgets('comment sort shows the active order and animates while opening', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AnimeWitcherCommentSortControl(
              tooltip: 'ترتيب التعليقات',
              selectedValue: AnimeWitcherCommentSort.mostLiked.name,
              items: AnimeWitcherCommentSortControl.menuItems(true),
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    expect(find.byKey(const ValueKey<String>('animated-sort-glyph')), findsOneWidget);

    await tester.tap(find.byTooltip('ترتيب التعليقات'));
    await tester.pump(const Duration(milliseconds: 80));

    final opacity = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey<String>('animated-sort-glyph')),
    );
    expect(opacity.opacity, 0);
  });

  test('native single-icon toolbar host stays exactly 46pt wide', () {
    final swiftSource = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(
      swiftSource,
      contains('isCompactSingleAction(actions)'),
      reason:
          'the native host needs an explicit compact path so its center mirrors Back',
    );
    expect(
      swiftSource,
      contains('if isCompactSingleAction(actions) { return 46 }'),
      reason: 'the transparent toolbar host must not keep the old 78pt minimum',
    );
  });
}

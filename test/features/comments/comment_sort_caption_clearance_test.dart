import 'package:animewitcher/core/utils/window_controls_inset.dart';
import 'package:animewitcher/features/comments/presentation/widgets/animewitcher_comment_sort_control.dart';
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
}

import 'package:animewitcher/features/details/presentation/widgets/details_tab_swipe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

Future<void> _pumpRtlDetailsPager(
  WidgetTester tester, {
  required TabController controller,
  Widget? detailsChild,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Column(
            children: [
              TabBar(
                controller: controller,
                isScrollable: false,
                tabs: const [
                  Tab(text: 'التفاصيل'),
                  Tab(text: 'الحلقات'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: controller,
                  children: [
                    _KeepAlivePage(
                      child:
                          detailsChild ??
                          const ColoredBox(
                            color: Colors.black,
                            child: Center(child: Text('تفاصيل الأنمي')),
                          ),
                    ),
                    const _KeepAlivePage(
                      child: ColoredBox(
                        color: Colors.black,
                        child: Center(child: Text('قائمة الحلقات')),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('extra-tabs swipe is ignored only while the details tab is showing', () {
    expect(
      ignoreDetailsEpisodesSwipe(
        selectedDetailsTab: 0,
        pointerInExtraTabsBounds: true,
      ),
      isTrue,
    );
    expect(
      ignoreDetailsEpisodesSwipe(
        selectedDetailsTab: 1,
        pointerInExtraTabsBounds: true,
      ),
      isFalse,
    );
    expect(
      ignoreDetailsEpisodesSwipe(
        selectedDetailsTab: 0,
        pointerInExtraTabsBounds: false,
      ),
      isFalse,
    );
  });

  testWidgets('Arabic details tabs keep Details on the right of Episodes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TabController(length: 2, vsync: tester);
    addTearDown(controller.dispose);
    await _pumpRtlDetailsPager(tester, controller: controller);

    expect(
      tester.getCenter(find.text('التفاصيل')).dx,
      greaterThan(tester.getCenter(find.text('الحلقات')).dx),
    );
    expect(controller.index, 0);
  });

  testWidgets('details TabBarView follows the finger in both RTL directions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TabController(length: 2, vsync: tester);
    addTearDown(controller.dispose);
    await _pumpRtlDetailsPager(tester, controller: controller);

    expect(controller.index, 0);
    expect(controller.offset, 0);

    final Size screen = tester.getSize(find.byType(MaterialApp));
    final TestGesture gesture = await tester.startGesture(
      Offset(screen.width * 0.5, screen.height * 0.55),
    );
    await gesture.moveBy(const Offset(110, 0));
    await tester.pump();

    // Native pager tracks the drag instead of jumping after pointer up.
    expect(controller.animation!.value, greaterThan(0.08));
    expect(controller.animation!.value, lessThan(0.95));
    expect(find.text('تفاصيل الأنمي'), findsOneWidget);
    expect(find.text('قائمة الحلقات'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.index, 1);
    expect(find.text('قائمة الحلقات'), findsOneWidget);

    final TestGesture back = await tester.startGesture(
      Offset(screen.width * 0.5, screen.height * 0.55),
    );
    await back.moveBy(const Offset(-110, 0));
    await tester.pump();
    expect(controller.animation!.value, greaterThan(0.05));
    expect(controller.animation!.value, lessThan(0.95));

    await back.up();
    await tester.pumpAndSettle();
    expect(controller.index, 0);
  });

  testWidgets(
    'RTL swipe on episodes returns to details even if extra-tabs stays mounted',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final extraTabsKey = GlobalKey();
      final controller = TabController(length: 2, vsync: tester);
      addTearDown(controller.dispose);

      await _pumpRtlDetailsPager(
        tester,
        controller: controller,
        detailsChild: ColoredBox(
          color: Colors.black,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              key: extraTabsKey,
              height: 520,
              width: 390,
              child: const ColoredBox(
                color: Colors.red,
                child: Center(child: Text('extra-tabs')),
              ),
            ),
          ),
        ),
      );

      expect(controller.index, 0);
      await tester.timedDragFrom(
        const Offset(80, 80),
        const Offset(140, 0),
        const Duration(milliseconds: 220),
      );
      await tester.pumpAndSettle();
      expect(controller.index, 1);
      expect(find.text('قائمة الحلقات'), findsOneWidget);

      // Drag over the stale extra-tabs rectangle (lower half). Native
      // TabBarView should still return to details.
      await tester.timedDragFrom(
        const Offset(200, 620),
        const Offset(-140, 0),
        const Duration(milliseconds: 220),
      );
      await tester.pumpAndSettle();
      expect(controller.index, 0);
    },
  );
}

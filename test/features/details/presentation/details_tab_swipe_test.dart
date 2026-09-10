import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/features/details/presentation/widgets/details_tab_swipe.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';

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

Future<void> _writeShot(WidgetTester tester, String filename, Key key) async {
  final artifacts = debugShotDirectory();
  if (artifacts == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(
      '${artifacts.path}/$filename',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _pumpRtlDetailsPager(
  WidgetTester tester, {
  required TabController controller,
  Widget? detailsChild,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'NotoSansArabic',
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFEEC60A),
          surface: Color(0xFF000000),
          onSurface: Color(0xFFE5E7EB),
        ),
      ),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('details-episodes-pager-shot'),
            child: Column(
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
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('desktop switcher mounts only the active heavy tab', (
    tester,
  ) async {
    var detailsBuilds = 0;
    var episodeBuilds = 0;

    Widget buildSwitcher(int selectedIndex) {
      return MaterialApp(
        home: DetailsDesktopTabSwitcher(
          selectedIndex: selectedIndex,
          transition: const AlwaysStoppedAnimation<double>(1),
          slideFrom: Offset.zero,
          detailsBuilder: (_) {
            detailsBuilds++;
            return const Text('desktop-details-body');
          },
          episodesBuilder: (_) {
            episodeBuilds++;
            return const Text('desktop-episodes-body');
          },
        ),
      );
    }

    await tester.pumpWidget(buildSwitcher(0));

    expect(find.text('desktop-details-body'), findsOneWidget);
    expect(find.text('desktop-episodes-body'), findsNothing);
    expect(find.byType(TabBarView), findsNothing);
    expect(detailsBuilds, 1);
    expect(episodeBuilds, 0);

    await tester.pumpWidget(buildSwitcher(1));
    await tester.pump();

    expect(find.text('desktop-details-body'), findsNothing);
    expect(find.text('desktop-episodes-body'), findsOneWidget);
    expect(find.byType(TabBarView), findsNothing);
    expect(detailsBuilds, 1);
    expect(episodeBuilds, 1);
  });

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
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    final controller = TabController(length: 2, vsync: tester);
    addTearDown(controller.dispose);
    await _pumpRtlDetailsPager(tester, controller: controller);

    expect(
      tester.getCenter(find.text('التفاصيل')).dx,
      greaterThan(tester.getCenter(find.text('الحلقات')).dx),
    );
    expect(controller.index, 0);
    await _writeShot(
      tester,
      'details_episodes_rtl_order.png',
      const ValueKey('details-episodes-pager-shot'),
    );
  });

  testWidgets('details TabBarView follows the finger in both RTL directions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

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

    await gesture.moveBy(const Offset(130, 0));
    await tester.pump();
    await _writeShot(
      tester,
      'details_tab_swipe_mid_drag.png',
      const ValueKey('details-episodes-pager-shot'),
    );
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

    await back.moveBy(const Offset(-130, 0));
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

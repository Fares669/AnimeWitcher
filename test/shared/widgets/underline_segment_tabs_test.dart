import 'package:animewitcher/shared/widgets/underline_segment_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets('wide page tabs are centered on $platform', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TabController(length: 4, vsync: tester);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: FilterStyleTabBar(
                controller: controller,
                tabs: const [
                  FilterStyleTab(label: 'السابق'),
                  FilterStyleTab(label: 'الحالي'),
                  FilterStyleTab(label: 'القادم'),
                  FilterStyleTab(label: 'المواسم الأخرى'),
                ],
              ),
            ),
          ),
        ),
      );
      expect(
        tester.widget<TabBar>(find.byType(TabBar)).tabAlignment,
        TabAlignment.center,
      );
      final first = tester.getRect(find.byType(Tab).first);
      final last = tester.getRect(find.byType(Tab).last);
      expect((last.left + first.right) / 2, closeTo(600, 1));
      await tester.tap(find.text('القادم'));
      await tester.pumpAndSettle();
      expect(controller.index, 2);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('phone tabs keep start alignment at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TabController(length: 2, vsync: tester);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilterStyleTabBar(
              controller: controller,
              tabs: const [
                FilterStyleTab(label: 'السابق'),
                FilterStyleTab(label: 'الحالي'),
              ],
            ),
          ),
        ),
      );
      expect(
        tester.widget<TabBar>(find.byType(TabBar)).tabAlignment,
        TabAlignment.start,
      );
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({TargetPlatform.iOS}));
  }

  testWidgets(
    'equal-width filter tabs keep a label-sized child without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = TabController(length: 3, vsync: tester);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: const ColorScheme.dark(primary: Color(0xFFEEC60A)),
          ),
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: FilterStyleTabBar(
                controller: controller,
                isScrollable: false,
                padding: EdgeInsets.zero,
                tabs: const [
                  FilterStyleTab(label: 'أنميات مشابهة'),
                  FilterStyleTab(label: 'ذات صلة'),
                  FilterStyleTab(label: 'الشخصيات'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.indicatorSize, isNull);

      final slots = tester
          .widgetList<InkWell>(
            find.descendant(
              of: find.byType(TabBar),
              matching: find.byType(InkWell),
            ),
          )
          .map((ink) => tester.getRect(find.byWidget(ink)))
          .toList();
      final labels = tester.widgetList<Tab>(find.byType(Tab)).map((tab) {
        return tester.getRect(find.byWidget(tab));
      }).toList();

      expect(slots, hasLength(3));
      expect(labels, hasLength(3));
      expect((slots[0].width - 390 / 3).abs(), lessThan(1));
      for (var i = 0; i < 3; i++) {
        expect(labels[i].width, lessThanOrEqualTo(slots[i].width + 0.5));
      }
      expect(labels[1].width, lessThan(slots[1].width * 0.85));
    },
  );
}

import 'package:animewitcher/features/details/presentation/widgets/details_layout_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe extends LeafRenderObjectWidget {
  const _Probe(this.onIntrinsic, {this.height = 80});
  final VoidCallback onIntrinsic;
  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ProbeBox(onIntrinsic, height);
}

class _ProbeBox extends RenderBox {
  _ProbeBox(this.onIntrinsic, this.height);
  final VoidCallback onIntrinsic;
  final double height;

  @override
  double computeMaxIntrinsicHeight(double width) {
    onIntrinsic();
    return height;
  }

  @override
  void performLayout() => size = constraints.constrain(Size(100, height));
}

void main() {
  testWidgets('single-column rows skip intrinsic passes and remain lazy', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var intrinsicCalls = 0;
    var configurations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverEpisodeCardGrid(
              itemCount: 1000,
              itemBuilder: (_, _) {
                configurations++;
                return _Probe(() => intrinsicCalls++);
              },
            ),
          ],
        ),
      ),
    );
    final mounted = find.byType(_Probe).evaluate().length;
    expect(mounted, lessThan(30));
    expect(configurations, inInclusiveRange(mounted, 30));
    final initialConfigurations = configurations;
    expect(intrinsicCalls, 0);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pump();
    expect(configurations, greaterThan(initialConfigurations));
    expect(configurations, lessThan(60));
    expect(intrinsicCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape rows retain equal height with an odd final card', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverEpisodeCardGrid(
              itemCount: 3,
              itemBuilder: (_, index) =>
                  _Probe(() {}, height: const [80.0, 120.0, 64.0][index]),
            ),
          ],
        ),
      ),
    );
    final boxes = tester
        .renderObjectList<RenderBox>(find.byType(_Probe))
        .toList();
    expect(boxes.map((box) => box.size.height), [120, 120, 64]);
    expect(boxes.last.size.width, closeTo(boxes.first.size.width, 1));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

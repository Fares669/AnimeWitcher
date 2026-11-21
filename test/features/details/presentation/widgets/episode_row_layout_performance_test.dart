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
    await tester.pumpWidget(
      MaterialApp(
        home: CustomScrollView(
          slivers: [
            SliverEpisodeCardGrid(
              children: [
                for (var i = 0; i < 1000; i++) _Probe(() => intrinsicCalls++),
              ],
            ),
          ],
        ),
      ),
    );
    expect(find.byType(_Probe).evaluate().length, lessThan(30));
    expect(intrinsicCalls, 0);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pump();
    expect(intrinsicCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape rows retain equal-height cards', (tester) async {
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
              children: [_Probe(() {}, height: 80), _Probe(() {}, height: 120)],
            ),
          ],
        ),
      ),
    );
    final boxes = tester
        .renderObjectList<RenderBox>(find.byType(_Probe))
        .toList();
    expect(boxes.map((box) => box.size.height), [120, 120]);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

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

  testWidgets(
    'RTL swipe on episodes returns to details even if extra-tabs stays mounted',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final extraTabsKey = GlobalKey();
      final controller = TabController(length: 2, vsync: tester);
      addTearDown(controller.dispose);
      var swipeDistance = 0.0;
      var startedAtBackEdge = false;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: RawGestureDetector(
                behavior: HitTestBehavior.translucent,
                gestures: <Type, GestureRecognizerFactory>{
                  DetailsEpisodesSwipeGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        DetailsEpisodesSwipeGestureRecognizer
                      >(
                        () => DetailsEpisodesSwipeGestureRecognizer(
                          shouldIgnore: (position) {
                            final extraContext = extraTabsKey.currentContext;
                            var inExtraTabs = false;
                            if (extraContext != null) {
                              final box = extraContext.findRenderObject();
                              if (box is RenderBox && box.hasSize) {
                                final local = box.globalToLocal(position);
                                inExtraTabs =
                                    local.dx >= 0 &&
                                    local.dy >= 0 &&
                                    local.dx <= box.size.width &&
                                    local.dy <= box.size.height;
                              }
                            }
                            return ignoreDetailsEpisodesSwipe(
                              selectedDetailsTab: controller.index,
                              pointerInExtraTabsBounds: inExtraTabs,
                            );
                          },
                        ),
                        (instance) {
                          instance
                            ..onStart = (details) {
                              swipeDistance = 0;
                              startedAtBackEdge =
                                  details.globalPosition.dx <= 24;
                            }
                            ..onUpdate = (details) {
                              if (startedAtBackEdge) return;
                              swipeDistance += details.primaryDelta ?? 0;
                            }
                            ..onEnd = (details) {
                              final distance = swipeDistance;
                              final velocity = details.primaryVelocity ?? 0;
                              final ignored = startedAtBackEdge;
                              swipeDistance = 0;
                              startedAtBackEdge = false;
                              if (ignored) return;
                              final swipeLeft =
                                  distance <= -72 || velocity <= -650;
                              final swipeRight =
                                  distance >= 72 || velocity >= 650;
                              if (swipeRight && controller.index != 1) {
                                controller.index = 1;
                              } else if (swipeLeft && controller.index != 0) {
                                controller.index = 0;
                              }
                            };
                        },
                      ),
                },
                child: TabBarView(
                  controller: controller,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _KeepAlivePage(
                      child: ColoredBox(
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
                    ),
                    const _KeepAlivePage(
                      child: ColoredBox(
                        color: Colors.black,
                        child: Center(child: Text('episodes-page')),
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

      expect(controller.index, 0);
      await tester.timedDragFrom(
        const Offset(80, 80),
        const Offset(140, 0),
        const Duration(milliseconds: 220),
      );
      await tester.pumpAndSettle();
      expect(controller.index, 1);
      expect(find.text('episodes-page'), findsOneWidget);

      // Drag over the stale extra-tabs rectangle (lower half). Without the
      // selected-tab guard this swipe would be ignored and we'd stay on 1.
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

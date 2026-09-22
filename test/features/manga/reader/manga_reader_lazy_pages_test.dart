import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_continuous_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

final class _LifecycleProbe extends StatefulWidget {
  const _LifecycleProbe({
    required this.label,
    required this.onDispose,
  });

  final String label;
  final VoidCallback onDispose;

  @override
  State<_LifecycleProbe> createState() => _LifecycleProbeState();
}

final class _LifecycleProbeState extends State<_LifecycleProbe> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  testWidgets('long webtoon does not eagerly build every page', (tester) async {
    final pages = List<MangaPage>.generate(
      120,
      (index) => MangaPage(
        index: index,
        imageUrl: 'https://example.test/$index.webp',
      ),
    );
    var builds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 800,
          child: MangaWebtoonReader(
            pages: pages,
            initialPage: 0,
            onPageChanged: (_) {},
            pageBuilder: (_, page) {
              builds++;
              return SizedBox(
                height: 500,
                child: Text('page-${page.index}'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(pages, hasLength(120));
    expect(builds, lessThan(10));
  });
  testWidgets('visited webtoon pages stay alive until chapter closes', (
    tester,
  ) async {
    final pages = List<MangaPage>.generate(
      80,
      (index) => MangaPage(
        index: index,
        imageUrl: 'https://example.test/keep-$index.webp',
      ),
    );
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var firstDisposed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 700,
          child: MangaWebtoonReader(
            pages: pages,
            initialPage: 0,
            controller: controller,
            onPageChanged: (_) {},
            pageBuilder: (_, page) => SizedBox(
              height: 500,
              child: _LifecycleProbe(
                label: 'probe-${page.index}',
                onDispose: page.index == 0
                    ? () => firstDisposed = true
                    : () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(firstDisposed, isFalse);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(firstDisposed, isFalse);
  });

  testWidgets('continuous reader keeps visited pages alive until chapter closes', (
    tester,
  ) async {
    final pages = List<MangaPage>.generate(
      80,
      (index) => MangaPage(
        index: index,
        imageUrl: 'https://example.test/continuous-$index.webp',
      ),
    );
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var firstDisposed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 700,
          child: MangaContinuousReader(
            pages: pages,
            initialPage: 0,
            scrollDirection: Axis.vertical,
            reverse: false,
            settings: const MangaReaderSettings(),
            controller: controller,
            onPageChanged: (_) {},
            pageBuilder: (_, page) => SizedBox(
              height: 500,
              child: _LifecycleProbe(
                label: 'continuous-probe-${page.index}',
                onDispose: page.index == 0
                    ? () => firstDisposed = true
                    : () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(firstDisposed, isFalse);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(firstDisposed, isFalse);
  });

}

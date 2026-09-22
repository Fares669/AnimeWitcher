import 'dart:io';

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

  testWidgets('progress rebuild never relocks loaded webtoon pages', (
    tester,
  ) async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_anchor_');
    addTearDown(() => temp.delete(recursive: true));
    const gif = <int>[
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00,
      0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
      0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x01, 0x00,
      0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00,
      0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44,
      0x01, 0x00, 0x3b,
    ];
    final file0 = File('${temp.path}/0000.gif')..writeAsBytesSync(gif);
    final file1 = File('${temp.path}/0001.gif')..writeAsBytesSync(gif);
    final pages = <MangaPage>[
      MangaPage(index: 0, imageUrl: file0.uri.toString()),
      MangaPage(index: 1, imageUrl: file1.uri.toString()),
    ];
    final firstImageKey = ValueKey<String>(
      'reader-local-${pages.first.imageUrl}-0',
    );

    Widget reader(int initialPage) => MaterialApp(
      home: SizedBox(
        height: 1200,
        child: MangaWebtoonReader(
          pages: pages,
          initialPage: initialPage,
          settings: const MangaReaderSettings(pagePreloadAmount: 1),
          onPageChanged: (_) {},
        ),
      ),
    );

    await tester.pumpWidget(reader(0));
    await tester.pumpAndSettle();
    expect(find.byKey(firstImageKey), findsOneWidget);

    // This models MangaReaderScreen rebuilding after pageIndex advances.
    await tester.pumpWidget(reader(1));
    await tester.pump();

    expect(find.byKey(firstImageKey), findsOneWidget);
  });

  testWidgets('progress rebuild never relocks loaded continuous pages', (
    tester,
  ) async {
    final temp = await Directory.systemTemp.createTemp(
      'aw_continuous_anchor_',
    );
    addTearDown(() => temp.delete(recursive: true));
    const gif = <int>[
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00,
      0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
      0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x01, 0x00,
      0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00,
      0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44,
      0x01, 0x00, 0x3b,
    ];
    final file0 = File('${temp.path}/0000.gif')..writeAsBytesSync(gif);
    final file1 = File('${temp.path}/0001.gif')..writeAsBytesSync(gif);
    final pages = <MangaPage>[
      MangaPage(index: 0, imageUrl: file0.uri.toString()),
      MangaPage(index: 1, imageUrl: file1.uri.toString()),
    ];
    final firstImageKey = ValueKey<String>(
      'reader-local-${pages.first.imageUrl}-0',
    );

    Widget reader(int initialPage) => MaterialApp(
      home: SizedBox(
        height: 1200,
        child: MangaContinuousReader(
          pages: pages,
          initialPage: initialPage,
          scrollDirection: Axis.vertical,
          reverse: false,
          settings: const MangaReaderSettings(pagePreloadAmount: 1),
          onPageChanged: (_) {},
        ),
      ),
    );

    await tester.pumpWidget(reader(0));
    await tester.pumpAndSettle();
    expect(find.byKey(firstImageKey), findsOneWidget);

    await tester.pumpWidget(reader(1));
    await tester.pump();

    expect(find.byKey(firstImageKey), findsOneWidget);
  });

}

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_continuous_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
// Keep the same Material test harness used by the app.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

void main() {
  testWidgets('only size changes that affect split crops rebuild the reader', (
    tester,
  ) async {
    final visibility = VisibilityDetectorController.instance;
    final previousInterval = visibility.updateInterval;
    visibility.updateInterval = Duration.zero;
    addTearDown(() => visibility.updateInterval = previousInterval);

    // The controlled callback models a local image's dimensions only. No
    // provider, filesystem contents or renderer-specific image is required.
    const pages = [
      MangaPage(index: 0, imageUrl: 'file:///__reader_fixture_missing__/0.jpg'),
    ];
    Widget reader({required bool split}) => MaterialApp(
      home: MangaContinuousReader(
        pages: pages,
        initialPage: 0,
        scrollDirection: Axis.vertical,
        reverse: false,
        settings: MangaReaderSettings(splitWidePages: split),
        onPageChanged: (_) {},
      ),
    );
    final images = find.byType(MangaPageImage);
    MangaPageImage fullImage() => tester.widget<MangaPageImage>(images);
    List<Rect?> crops() => tester
        .widgetList<MangaPageImage>(images)
        .map((image) => image.sourceRect)
        .toList();
    List<Rect> halves(double width, double height) => [
      Rect.fromLTWH(0, 0, width / 2, height),
      Rect.fromLTWH(width / 2, 0, width / 2, height),
    ];

    await tester.pumpWidget(reader(split: false));
    await tester.pumpAndSettle();
    final initialImage = fullImage();
    final notifySize = initialImage.onImageSize!;
    notifySize(const Size(900, 1600));
    await tester.pump();
    expect(fullImage(), same(initialImage));

    notifySize(const Size(2400, 1500));
    await tester.pump();
    expect(fullImage(), same(initialImage));
    await tester.pumpWidget(reader(split: true));
    await tester.pumpAndSettle();
    expect(crops(), unorderedEquals(halves(2400, 1500)));

    notifySize(const Size(2600, 1500));
    await tester.pumpAndSettle();
    expect(crops(), unorderedEquals(halves(2600, 1500)));

    notifySize(const Size(900, 1600));
    await tester.pumpAndSettle();
    final portrait = fullImage();
    expect(portrait.sourceRect, isNull);
    notifySize(const Size(950, 1600));
    await tester.pump();
    expect(fullImage(), same(portrait));
  });
}

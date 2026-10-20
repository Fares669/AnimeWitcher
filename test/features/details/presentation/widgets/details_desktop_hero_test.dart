import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_desktop_hero.dart';
import 'package:animewitcher/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final entry in <String, TextDirection>{
    'مغامرات البطل في العالم الآخر': TextDirection.rtl,
    'The Long Adventure in Another World': TextDirection.ltr,
    '2026 مغامرات البطل في العالم الآخر': TextDirection.rtl,
    '86 The Long Adventure in Another World': TextDirection.ltr,
    'مغامرات Naruto في العالم الآخر': TextDirection.rtl,
    'Naruto and the Adventure in العالم': TextDirection.ltr,
  }.entries) {
    testWidgets('title keeps natural direction: ${entry.key}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final item = MultimediaItem(
        title: entry.key,
        url: 'https://example.test/title-direction',
        posterUrl: '',
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: DetailsDesktopHero(
                compact: true,
                showPoster: true,
                displayItem: item,
                details: item,
                detailsState: AsyncValue<MultimediaItem?>.data(item),
                isMovie: false,
                itemUrl: item.url,
                onRefresh: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final title = find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == entry.key &&
            widget.style?.fontWeight == FontWeight.bold,
      );
      final text = tester.widget<Text>(title);
      expect(text.textDirection, entry.value);
      expect(text.textAlign, TextAlign.right);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.data, entry.key);
      expect(tester.takeException(), isNull);
    });
  }

  for (final manga in [false, true]) {
    for (final size in [
      const Size(390, 844),
      const Size(844, 390),
      const Size(1280, 900),
    ]) {
      testWidgets(
        '${manga ? 'manga' : 'anime'} header uses phone RTL and desktop LTR at $size',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final item = MultimediaItem(
            title: 'Tsuihou sareta Cheat Fuyo Majutsushi',
            url: 'https://example.test/header',
            posterUrl: '',
            year: 2026,
            contentRating: '13+',
            status: ShowStatus.ongoing,
          );
          final compact = size.width < 1000;
          final direction = compact ? TextDirection.rtl : TextDirection.ltr;
          final showPoster = manga || compact;
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                home: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Scaffold(
                    body: DetailsDesktopHero(
                      compact: compact,
                      manga: manga,
                      showPoster: showPoster,
                      displayItem: item,
                      details: item,
                      detailsState: AsyncValue<MultimediaItem?>.data(item),
                      isMovie: false,
                      itemUrl: item.url,
                      onRefresh: () async {},
                      heroActions: const Text('الإجراءات'),
                      story: const Text('القصة'),
                      child: const Text('الحلقات والفصول'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final poster = find.byKey(const ValueKey('details-hero-poster'));
          final title = find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                widget.data == item.title &&
                widget.style?.fontWeight == FontWeight.bold,
          );
          if (showPoster) {
            if (compact) {
              expect(
                tester.getRect(poster).left,
                greaterThan(tester.getRect(title).right),
              );
            } else {
              expect(
                tester.getRect(poster).right,
                lessThan(tester.getRect(title).left),
              );
            }
          } else {
            expect(poster, findsNothing);
            expect(tester.getRect(title).left, closeTo(60, 0.5));
          }
          expect(
            tester.renderObject<RenderParagraph>(title).textDirection,
            TextDirection.ltr,
          );
          expect(
            tester.widget<Text>(title).textAlign,
            compact ? TextAlign.right : TextAlign.start,
          );
          for (final text
              in find
                  .descendant(
                    of: find.byType(MetadataBar),
                    matching: find.byType(Text),
                  )
                  .evaluate()) {
            expect(
              (text.renderObject! as RenderParagraph).textDirection,
              direction,
            );
          }
          expect(
            tester.getRect(find.text('2026')).left,
            compact
                ? greaterThan(tester.getRect(find.text('مستمر')).left)
                : lessThan(tester.getRect(find.text('مستمر')).left),
          );
          for (final label in ['الإجراءات', 'القصة', 'الحلقات والفصول']) {
            expect(
              Directionality.of(tester.element(find.text(label))),
              TextDirection.rtl,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final manga in [false, true]) {
    for (final compact in [false, true]) {
      testWidgets(
        '${manga ? 'manga' : 'anime'} ${compact ? 'phone' : 'desktop'} opens artwork only from the poster',
        (tester) async {
          tester.view.physicalSize = compact
              ? const Size(390, 844)
              : const Size(1280, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final item = MultimediaItem(
            title: 'Poster gesture test',
            url: 'https://example.test/poster-gesture',
            posterUrl: '',
          );
          var opens = 0;
          await tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                home: Scaffold(
                  body: DetailsDesktopHero(
                    compact: compact,
                    manga: manga,
                    showPoster: true,
                    displayItem: item,
                    details: item,
                    detailsState: AsyncValue<MultimediaItem?>.data(item),
                    isMovie: false,
                    itemUrl: item.url,
                    onRefresh: () async {},
                    onPosterTap: () => opens++,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final title = find.byWidgetPredicate(
            (widget) => widget is Text &&
                widget.data == item.title &&
                widget.style?.fontWeight == FontWeight.bold,
          );
          await tester.tap(title);
          await tester.pump();
          expect(opens, 0);
          await tester.tap(find.byKey(const ValueKey('details-hero-poster')));
          await tester.pump();
          expect(opens, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'portrait phone hero keeps a wide banner below the top isolation and centers info on the larger poster',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final item = MultimediaItem(
        title: 'One Piece',
        url: 'https://example.test/one-piece',
        posterUrl: '',
        bannerUrl: '',
        catalogType: 'مسلسل',
        year: 1999,
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(390, 844),
                viewPadding: EdgeInsets.only(top: 44),
              ),
              child: Scaffold(
                body: DetailsDesktopHero(
                  compact: true,
                  showPoster: true,
                  displayItem: item,
                  details: item,
                  detailsState: AsyncValue<MultimediaItem?>.data(item),
                  isMovie: false,
                  itemUrl: item.url,
                  onRefresh: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final isolation = find.byKey(
        const ValueKey<String>('details-hero-top-isolation'),
      );
      final banner = find.byKey(
        const ValueKey<String>('details-hero-portrait-banner'),
      );
      final poster = find.byKey(const ValueKey<String>('details-hero-poster'));
      final info = find.byKey(const ValueKey<String>('details-hero-info'));

      expect(isolation, findsOneWidget);
      expect(banner, findsOneWidget);
      expect(poster, findsOneWidget);
      expect(info, findsOneWidget);

      final isolationRect = tester.getRect(isolation);
      final bannerRect = tester.getRect(banner);
      final posterRect = tester.getRect(poster);
      final infoRect = tester.getRect(info);

      expect(isolationRect.top, closeTo(0, 0.5));
      expect(isolationRect.height, closeTo(44, 0.5));
      expect(bannerRect.top, closeTo(isolationRect.bottom, 0.5));
      expect(bannerRect.width, closeTo(390, 0.5));
      expect(bannerRect.height, closeTo(390 * 9 / 16, 1));
      expect(posterRect.width, greaterThanOrEqualTo(118));
      expect(
        (posterRect.center.dy - infoRect.center.dy).abs(),
        lessThanOrEqualTo(2),
      );
    },
  );
}

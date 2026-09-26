import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_desktop_hero.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/fallback_poster_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A synopsis that opens to many times its height, as "عرض المزيد" does.
class _Story extends StatefulWidget {
  const _Story();

  @override
  State<_Story> createState() => _StoryState();
}

class _StoryState extends State<_Story> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: _open ? 900 : 90),
        TextButton(
          key: const ValueKey<String>('story-more'),
          onPressed: () => setState(() => _open = !_open),
          child: const Text('عرض المزيد'),
        ),
      ],
    );
  }
}

void main() {
  testWidgets('a long name standing in for the logo keeps all its lines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const title =
        'Hell Mode: Yarikomizuki no Gamer wa Hai Settei no Isekai de '
        'Tanjou suru';
    final item = MultimediaItem(
      title: title,
      url: 'https://example.test/hell-mode',
      posterUrl: '',
      logoUrl: 'https://example.test/logo.png',
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DetailsDesktopHero(
              displayItem: item,
              details: item,
              detailsState: AsyncData<MultimediaItem?>(item),
              isMovie: false,
              itemUrl: item.url,
              onRefresh: () async {},
              compact: true,
              showPoster: true,
              slivers: const <Widget>[],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The logo has not come, so the name stands in for it: three lines of
    // it, not the logo's 56 points with the last line cut away.
    final name = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && widget.data == title && widget.maxLines == 3,
      ),
    );
    expect(name.height, greaterThan(64));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 100));
  });

  // The phone's header and the wider one PC and tablet use.
  for (final (name, size, compact) in <(String, Size, bool)>[
    ('phone', const Size(400, 860), true),
    ('PC and tablet', const Size(1280, 800), false),
  ]) {
    testWidgets('$name: opening the synopsis leaves the picture its size', (
      tester,
    ) async {
      await _expectPictureKeepsItsSize(tester, size: size, compact: compact);
    });
  }
}

Future<void> _expectPictureKeepsItsSize(
  WidgetTester tester, {
  required Size size,
  required bool compact,
}) async {
  {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final item = MultimediaItem(
      title: 'Kore Kaite Shine',
      url: 'https://example.test/kore',
      posterUrl: '',
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DetailsDesktopHero(
              displayItem: item,
              details: item,
              detailsState: AsyncData<MultimediaItem?>(item),
              isMovie: false,
              itemUrl: item.url,
              onRefresh: () async {},
              compact: compact,
              showPoster: true,
              story: const _Story(),
              slivers: const <Widget>[],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final picture = find.byType(FallbackPosterImage).first;
    final before = tester.getRect(picture);
    final moreBefore = tester.getTopLeft(
      find.byKey(const ValueKey('story-more')),
    );

    await tester.tap(find.byKey(const ValueKey('story-more')));
    await tester.pump();

    // The synopsis opened: what follows it moved down...
    final moreAfter = tester.getTopLeft(
      find.byKey(const ValueKey('story-more'), skipOffstage: false),
    );
    expect(moreAfter.dy, greaterThan(moreBefore.dy + 500));
    // ...and the picture did not grow with it, so it did not zoom in.
    final after = tester.getRect(picture);
    expect(after.height, closeTo(before.height, 0.5));
    expect(after.width, closeTo(before.width, 0.5));
    // It still runs on under the start of the synopsis.
    expect(before.bottom, greaterThan(moreBefore.dy - 200));

    expect(tester.takeException(), isNull);
    // The fallback picture looks up artwork on a short timer.
    await tester.pump(const Duration(milliseconds: 100));
  }
}

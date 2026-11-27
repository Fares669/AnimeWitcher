import 'package:animewitcher/shared/widgets/anime_catalog_shimmer.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:animewitcher/shared/widgets/shimmer_placeholder.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shimmer/shimmer.dart';

Future<void> _pumpCatalog(
  WidgetTester tester, {
  bool characterCaptionSpace = false,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimeCatalogShimmer(
            itemCount: 6,
            physics: const NeverScrollableScrollPhysics(),
            characterCaptionSpace: characterCaptionSpace,
          ),
        ),
      ),
    );
    await tester.pump();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Finder _posterInCard(int index) {
  final card = find.byType(AnimePosterShimmer).at(index);
  return find
      .descendant(of: card, matching: find.byType(ShimmerPlaceholder))
      .first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shared mobile catalog metrics match the search reference', () {
    expect(MultimediaCardLayout.handsetPortraitGridColumns, 3);
    expect(MultimediaCardLayout.handsetPortraitGridHorizontalPadding, 12);
    expect(MultimediaCardLayout.handsetPortraitGridCrossAxisSpacing, 10);
    expect(MultimediaCardLayout.handsetPortraitGridMainAxisSpacing, 14);
    expect(
      MultimediaCardLayout.characterGridAspectRatio,
      greaterThan(MultimediaCardLayout.portraitGridAspectRatio),
    );
  });

  testWidgets('catalog skeleton uses the active theme surface color', (
    tester,
  ) async {
    const skeletonSurface = Color(0xFF345678);
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7A4DFF),
      brightness: Brightness.dark,
    ).copyWith(surfaceContainerHighest: skeletonSurface);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme),
        home: const Scaffold(
          body: SizedBox(
            width: 120,
            height: 240,
            child: AnimePosterShimmer(),
          ),
        ),
      ),
    );
    await tester.pump();

    final shimmer = tester.widget<Shimmer>(find.byType(Shimmer).first);
    final gradient = shimmer.gradient as LinearGradient;
    expect(gradient.colors.first, skeletonSurface);
  });

  testWidgets('long skeleton keeps its layout and stops scheduling frames', (
    tester,
  ) async {
    const key = ValueKey('bounded-catalog-shimmer');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ShimmerPlaceholder.rectangular(
              key: key,
              width: 120,
              height: 180,
            ),
          ),
        ),
      ),
    );
    final box = find.byKey(key);
    expect(find.byType(Shimmer), findsOneWidget);
    final geometry = tester.getRect(box);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(find.byType(Shimmer), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(Shimmer), findsNothing);
    expect(tester.getRect(box), geometry);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion renders a static skeleton immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: ShimmerPlaceholder.rectangular(width: 120, height: 180),
        ),
      ),
    );
    expect(find.byType(ShimmerPlaceholder), findsOneWidget);
    expect(find.byType(Shimmer), findsNothing);
  });

  testWidgets('anime skeleton renders poster, name and metadata lines', (
    tester,
  ) async {
    await _pumpCatalog(tester);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final firstCard = find.byType(AnimePosterShimmer).first;
    expect(
      find.descendant(
        of: firstCard,
        matching: find.byType(ShimmerPlaceholder),
      ),
      findsNWidgets(3),
    );
  });

  testWidgets('catalog skeleton poster matches the final bounded card size', (
    tester,
  ) async {
    await _pumpCatalog(tester);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final first = tester.getRect(_posterInCard(0));
    final fourth = tester.getRect(_posterInCard(3));
    const expectedWidth =
        (390 -
            MultimediaCardLayout.handsetPortraitGridHorizontalPadding * 2 -
            MultimediaCardLayout.handsetPortraitGridCrossAxisSpacing * 2) /
        MultimediaCardLayout.handsetPortraitGridColumns;
    final context = tester.element(find.byType(AnimeCatalogShimmer));
    final expectedCaption = MultimediaCardLayout.animeCaptionExtent(context);
    const expectedCellHeight =
        expectedWidth / MultimediaCardLayout.portraitGridAspectRatio;

    expect(first.width, closeTo(expectedWidth, 0.5));
    expect(first.height, closeTo(expectedCellHeight - expectedCaption, 0.75));

    final rowStride = fourth.top - first.top;
    final reservedCaptionSpace =
        rowStride -
        first.height -
        MultimediaCardLayout.handsetPortraitGridMainAxisSpacing;
    expect(reservedCaptionSpace, closeTo(expectedCaption, 0.75));
  });

  testWidgets('character loading renders name only and keeps smaller caption', (
    tester,
  ) async {
    await _pumpCatalog(tester);
    final animeFirst = tester.getRect(_posterInCard(0));
    final animeFourth = tester.getRect(_posterInCard(3));
    final animeReserved =
        animeFourth.top -
        animeFirst.top -
        animeFirst.height -
        MultimediaCardLayout.handsetPortraitGridMainAxisSpacing;

    await _pumpCatalog(tester, characterCaptionSpace: true);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final characterFirst = tester.getRect(_posterInCard(0));
    final characterFourth = tester.getRect(_posterInCard(3));
    final characterReserved =
        characterFourth.top -
        characterFirst.top -
        characterFirst.height -
        MultimediaCardLayout.handsetPortraitGridMainAxisSpacing;

    final firstCharacterCard = find.byType(AnimePosterShimmer).first;
    expect(
      find.descendant(
        of: firstCharacterCard,
        matching: find.byType(ShimmerPlaceholder),
      ),
      findsNWidgets(2),
    );

    final context = tester.element(find.byType(AnimeCatalogShimmer));
    expect(
      animeReserved,
      closeTo(MultimediaCardLayout.animeCaptionExtent(context), 0.75),
    );
    expect(
      characterReserved,
      closeTo(MultimediaCardLayout.characterCaptionExtent(context), 0.75),
    );
    expect(characterFirst.width, closeTo(animeFirst.width, 0.5));
    expect(characterReserved, lessThan(animeReserved));
  });

  testWidgets('poster caption skeleton stays left aligned inside RTL rails', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Directionality(
            textDirection: TextDirection.rtl,
            child: Center(
              child: SizedBox(
                width: 120,
                height: 240,
                child: const AnimePosterShimmer(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final card = find.byType(AnimePosterShimmer);
    final placeholders = find.descendant(
      of: card,
      matching: find.byType(ShimmerPlaceholder),
    );
    expect(placeholders, findsNWidgets(3));

    final cardRect = tester.getRect(card);
    final titleRect = tester.getRect(placeholders.at(1));
    final metadataRect = tester.getRect(placeholders.at(2));

    expect(titleRect.left, closeTo(cardRect.left + 2, 0.5));
    expect(metadataRect.left, closeTo(cardRect.left + 2, 0.5));
    expect(titleRect.right, lessThan(cardRect.right));
    expect(metadataRect.right, lessThan(cardRect.right));
  });
}

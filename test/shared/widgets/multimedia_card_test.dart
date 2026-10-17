import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/utils/catalog_rating.dart';
import 'package:animewitcher/core/theme/app_theme.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _cardApp({required MultimediaCard card, ThemeData? theme}) {
  return MaterialApp(
    locale: const Locale('ar'),
    theme: theme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: card),
  );
}

void main() {
  for (final badge in ['  الحلقة ٠٠٢.٥  ', '  Chapter 0002.50  ']) {
    testWidgets('preserves the complete episode/chapter badge $badge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _cardApp(
          card: MultimediaCard(
            imageUrl: null,
            title: 'Show',
            episodeBadge: badge,
            heroTag: 'raw-name-card',
            onTap: () {},
          ),
        ),
      );

      expect(find.text(badge), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel('Show، $badge')),
        matchesSemantics(
          label: 'Show، $badge',
          hint: 'عرض التفاصيل',
          isButton: true,
          hasTapAction: true,
        ),
      );
    });
  }

  test('home rail height uses the same aspect ratio as catalog grids', () {
    expect(
      MultimediaCardLayout.listHeight(130, isPortrait: true),
      closeTo(130 / MultimediaCardLayout.portraitGridAspectRatio, 0.001),
    );
    expect(
      MultimediaCardLayout.listHeight(
        200,
        isPortrait: true,
        isDesktop: true,
      ),
      closeTo(200 / MultimediaCardLayout.desktopPortraitGridAspectRatio, 0.001),
    );
  });

  testWidgets('announces a content card as an actionable details button', (
    tester,
  ) async {
    await tester.pumpWidget(
      _cardApp(
        card: MultimediaCard(
          imageUrl: null,
          title: 'عنوان تجريبي',
          heroTag: 'semantic-test-card',
          onTap: () {},
        ),
      ),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('عنوان تجريبي')),
      matchesSemantics(
        label: 'عنوان تجريبي',
        hint: 'عرض التفاصيل',
        isButton: true,
        hasTapAction: true,
      ),
    );
  });

  testWidgets('includes the episode badge in the announced label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _cardApp(
        card: MultimediaCard(
          imageUrl: null,
          title: 'عنوان تجريبي',
          episodeBadge: 'الحلقة 12',
          heroTag: 'semantic-test-card-badge',
          onTap: () {},
        ),
      ),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('عنوان تجريبي، الحلقة 12')),
      matchesSemantics(
        label: 'عنوان تجريبي، الحلقة 12',
        hint: 'عرض التفاصيل',
        isButton: true,
        hasTapAction: true,
      ),
    );
  });

  testWidgets('renders the content title left-to-right in an Arabic app', (
    tester,
  ) async {
    const title = 'Ore dake Level Up na Ken';
    await tester.pumpWidget(
      _cardApp(
        card: MultimediaCard(
          imageUrl: null,
          title: title,
          heroTag: 'ltr-title-card',
          onTap: () {},
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == title &&
            widget.textDirection == TextDirection.ltr,
      ),
      findsOneWidget,
    );
  });

  testWidgets('places the title under the poster with a gray caption', (
    tester,
  ) async {
    await tester.pumpWidget(
      _cardApp(
        card: MultimediaCard(
          imageUrl: null,
          title: 'عمل تجريبي',
          subtitle: 'مسلسل',
          year: 2012,
          heroTag: 'caption-card',
          onTap: () {},
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == 'عمل تجريبي' &&
            widget.textAlign == TextAlign.left &&
            widget.textDirection == TextDirection.ltr,
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == 'مسلسل' &&
            widget.textAlign == TextAlign.left &&
            widget.textDirection == TextDirection.ltr,
      ),
      findsOneWidget,
    );
    expect(find.text('2012'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('عمل تجريبي، 2012، مسلسل')),
      matchesSemantics(
        label: 'عمل تجريبي، 2012، مسلسل',
        hint: 'عرض التفاصيل',
        isButton: true,
        hasTapAction: true,
      ),
    );
  });

  testWidgets('shows the latest-episode badge on the poster', (tester) async {
    await tester.pumpWidget(
      _cardApp(
        card: MultimediaCard(
          imageUrl: null,
          title: 'عمل تجريبي',
          episodeBadge: 'الحلقة 9',
          subtitle: 'منذ ساعتين',
          heroTag: 'latest-card',
          onTap: () {},
        ),
      ),
    );

    expect(find.text('الحلقة 9'), findsOneWidget);
    expect(find.text('منذ ساعتين'), findsOneWidget);
    expect(find.text('2012'), findsNothing);
  });

  testWidgets('uses dark caption colors in the light theme', (tester) async {
    await tester.pumpWidget(
      _cardApp(
        theme: AppTheme.createLightTheme(null),
        card: MultimediaCard(
          imageUrl: null,
          title: 'عمل تجريبي',
          subtitle: 'فيلم',
          heroTag: 'light-caption-card',
          onTap: () {},
        ),
      ),
    );

    final title = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == 'عمل تجريبي' &&
            widget.textAlign == TextAlign.left,
      ),
    );
    final type = tester.widget<Text>(find.text('فيلم'));
    expect(title.style?.color, const Color(0xFF111111));
    expect(type.style?.color, const Color(0xFF1A1A1A));
    expect(title.textAlign, TextAlign.left);
    expect(type.textAlign, TextAlign.left);
  });

  testWidgets('keeps light caption colors in the dark theme', (tester) async {
    await tester.pumpWidget(
      _cardApp(
        theme: AppTheme.createDarkTheme(null),
        card: MultimediaCard(
          imageUrl: null,
          title: 'عمل تجريبي',
          subtitle: 'خاصة',
          heroTag: 'dark-caption-card',
          onTap: () {},
        ),
      ),
    );

    final title = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data == 'عمل تجريبي' &&
            widget.textAlign == TextAlign.left,
      ),
    );
    final type = tester.widget<Text>(find.text('خاصة'));
    expect(title.style?.color, Colors.white.withValues(alpha: 0.92));
    expect(type.style?.color, Colors.white.withValues(alpha: 0.45));
  });

  testWidgets('renders MAL as a compact filled blue badge', (tester) async {
    await tester.pumpWidget(
      _cardApp(
        card: MultimediaCard(
          imageUrl: null,
          title: 'MAL card',
          subtitle: 'مسلسل',
          catalogRating: const CatalogRating(
            source: CatalogRatingSource.mal,
            score: 8.73,
          ),
          heroTag: 'mal-rating-card',
          onTap: () {},
        ),
      ),
    );

    final badge = tester.widget<Container>(
      find.byKey(const Key('catalog-rating-mal-source')),
    );
    expect((badge.decoration as BoxDecoration).color, const Color(0xFF2E51A2));
    final label = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('catalog-rating-mal-source')),
        matching: find.text('MAL'),
      ),
    );
    expect(label.style?.color, Colors.white);
    expect(find.text('8.73'), findsOneWidget);
  });

  testWidgets('renders IMDb as a compact filled yellow badge', (tester) async {
    await tester.pumpWidget(
      _cardApp(
        card: MultimediaCard(
          imageUrl: null,
          title: 'IMDb card',
          subtitle: 'مسلسل',
          catalogRating: const CatalogRating(
            source: CatalogRatingSource.imdb,
            score: 8.4,
          ),
          heroTag: 'imdb-rating-card',
          onTap: () {},
        ),
      ),
    );

    final badge = tester.widget<Container>(
      find.byKey(const Key('catalog-rating-imdb-source')),
    );
    expect((badge.decoration as BoxDecoration).color, const Color(0xFFF5C518));
    final label = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('catalog-rating-imdb-source')),
        matching: find.text('IMDb'),
      ),
    );
    expect(label.style?.color, Colors.black);
    expect(find.text('8.4'), findsOneWidget);
  });

  test('catalog cards shimmer posters by default while artwork loads', () {
    final card = MultimediaCard.fromItem(
      item: MultimediaItem(
        title: 'Bleach',
        url: 'https://example.test/bleach',
        posterUrl: 'https://example.test/poster.png',
      ),
      heroTag: 'default-shimmer',
      onTap: () {},
    );

    expect(card.showImageLoadingShimmer, isTrue);
  });
}

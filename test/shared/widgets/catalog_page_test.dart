import 'package:animewitcher/shared/widgets/anime_catalog_shimmer.dart';
import 'package:animewitcher/shared/widgets/catalog_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const topInset = 100.0;

  Widget wrap(CatalogBody body) => MaterialApp(
    home: Scaffold(body: body),
  );

  CatalogBody body({
    int itemCount = 0,
    bool isLoading = false,
    String? errorMessage,
    Future<void> Function()? onRetry,
    String? emptyMessage,
    CatalogFooter footer = CatalogFooter.none,
    int footerCount = 1,
  }) {
    return CatalogBody(
      topInset: topInset,
      itemCount: itemCount,
      isLoading: isLoading,
      errorMessage: errorMessage,
      onRetry: onRetry,
      emptyMessage: emptyMessage,
      footer: footer,
      footerCount: footerCount,
      itemBuilder: (context, index) => SizedBox(
        key: ValueKey<String>('item-$index'),
        height: 10,
      ),
    );
  }

  testWidgets('loading shimmer starts below the header inset', (tester) async {
    await tester.pumpWidget(wrap(body(isLoading: true)));
    final poster = tester.getRect(find.byType(AnimePosterShimmer).first);
    expect(poster.top, greaterThanOrEqualTo(topInset));
  });

  testWidgets('grid content starts at the inset plus the standard gap', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(body(itemCount: 3)));
    final item = tester.getRect(find.byKey(const ValueKey('item-0')));
    expect(item.top, topInset + 16);
  });

  testWidgets('error state shows its message and retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      wrap(
        body(
          errorMessage: 'تعذر التحميل',
          onRetry: () async => retries++,
        ),
      ),
    );
    expect(find.text('تعذر التحميل'), findsOneWidget);
    await tester.tap(find.text('إعادة المحاولة'));
    expect(retries, 1);
  });

  testWidgets('empty state shows its message below the inset', (tester) async {
    await tester.pumpWidget(wrap(body(emptyMessage: 'لا توجد عناصر')));
    expect(find.text('لا توجد عناصر'), findsOneWidget);
    final rect = tester.getRect(find.text('لا توجد عناصر'));
    expect(rect.top, greaterThan(topInset));
  });

  testWidgets('a loading footer grows shimmer cells after the items', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(body(itemCount: 2, footer: CatalogFooter.loading)),
    );
    expect(find.byType(AnimePosterShimmer), findsWidgets);
    expect(find.byKey(const ValueKey('item-1')), findsOneWidget);
  });
}

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item(String title, String id) {
  return MultimediaItem(
    title: title,
    url: 'https://example.test/$id',
    posterUrl: '',
  );
}

void main() {
  testWidgets('related and more-like-this rails start on the right', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ListView(
            children: [
              RecommendationsCarousel(
                title: 'ذات صلة',
                items: [
                  _item('RelatedOne', 'r1'),
                  _item('RelatedTwo', 'r2'),
                  _item('RelatedThree', 'r3'),
                ],
                showRelationBadge: true,
                onItemTap: (_) {},
              ),
              RecommendationsCarousel(
                items: [
                  _item('MoreOne', 'm1'),
                  _item('MoreTwo', 'm2'),
                  _item('MoreThree', 'm3'),
                ],
                onItemTap: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('ذات صلة'), findsOneWidget);
    expect(find.text('المزيد مثل هذا'), findsOneWidget);

    final relatedFirst = tester.getTopLeft(
      find.byKey(const ValueKey('ذات صلة-rail-0')),
    );
    final relatedLast = tester.getTopLeft(
      find.byKey(const ValueKey('ذات صلة-rail-2')),
    );
    expect(relatedFirst.dx, greaterThan(relatedLast.dx));

    final moreFirst = tester.getTopLeft(
      find.byKey(const ValueKey('more-like-this-rail-0')),
    );
    final moreLast = tester.getTopLeft(
      find.byKey(const ValueKey('more-like-this-rail-2')),
    );
    expect(moreFirst.dx, greaterThan(moreLast.dx));
  });
}

import 'package:animewitcher/core/extensions/providers/anime_rift_account_content.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_comments.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/features/comments/presentation/anime_rift_my_comments_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixtureRift extends AnimeRiftProvider {
  int reads = 0;

  @override
  Future<bool> restoreAccountSession() async => true;

  @override
  Future<AnimeRiftMyCommentPage> loadMyComments({int page = 0}) async {
    reads++;
    return const AnimeRiftMyCommentPage(
      items: [
        AnimeRiftMyComment(
          comment: AnimeRiftComment(
            id: 'own-comment',
            text: 'حرق النهاية',
            author: 'صاحب الحساب',
            likes: 7,
            replies: 2,
            spoiler: true,
          ),
          animeTitle: 'أنمي ريفت',
          animeId: 'anime123',
          isReview: true,
        ),
      ],
      hasMore: false,
    );
  }
}

class _SelectedProvider extends ActiveProvider {
  _SelectedProvider(this.value);
  final AnimeWitcherProvider? value;

  @override
  AnimeWitcherProvider? build() => value;

  void choose(AnimeWitcherProvider? next) => state = next;
}

Widget _app(_FixtureRift rift, {bool selected = true}) => ProviderScope(
  overrides: [
    activeProviderProvider.overrideWith(
      () => _SelectedProvider(selected ? rift : null),
    ),
  ],
  child: MaterialApp(home: AnimeRiftMyCommentsScreen(provider: rift)),
);

void main() {
  setUp(() => AnimeRiftLocalAccountScope.activate('alice'));
  tearDown(AnimeRiftLocalAccountScope.reset);

  testWidgets('My Comments uses Witcher cards and hides spoiler text', (
    tester,
  ) async {
    final rift = _FixtureRift();
    await tester.pumpWidget(_app(rift));
    await tester.pumpAndSettle();
    expect(rift.reads, 1);
    expect(find.text('تعليقاتي'), findsOneWidget);
    expect(find.text('أنمي ريفت'), findsOneWidget);
    expect(find.text('مراجعة'), findsOneWidget);
    expect(find.text('حرق النهاية'), findsNothing);
    await tester.tap(find.text('تعليق يحتوي على حرق — إظهار'));
    await tester.pump();
    expect(find.text('حرق النهاية'), findsOneWidget);
  });

  testWidgets('signing out clears previously loaded Rift comments', (
    tester,
  ) async {
    final rift = _FixtureRift();
    await tester.pumpWidget(_app(rift));
    await tester.pumpAndSettle();
    expect(find.text('أنمي ريفت'), findsOneWidget);
    AnimeRiftLocalAccountScope.reset();
    await tester.pumpWidget(_app(rift));
    await tester.pumpAndSettle();
    expect(find.text('أنمي ريفت'), findsNothing);
    expect(find.textContaining('اربط حساب'), findsOneWidget);
    expect(rift.reads, 1);
  });

  testWidgets('switching provider hides another account comments', (
    tester,
  ) async {
    final rift = _FixtureRift();
    await tester.pumpWidget(_app(rift));
    await tester.pumpAndSettle();
    expect(find.text('أنمي ريفت'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AnimeRiftMyCommentsScreen)),
    );
    (container.read(activeProviderProvider.notifier) as _SelectedProvider)
        .choose(null);
    await tester.pumpAndSettle();
    expect(find.text('أنمي ريفت'), findsNothing);
    expect(find.textContaining('انتقل إلى حساب'), findsOneWidget);
  });
}

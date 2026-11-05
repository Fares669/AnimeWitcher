import 'package:animewitcher/core/extensions/providers/anime_rift_comments.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/features/comments/presentation/anime_rift_comments_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRiftCommentsProvider extends AnimeRiftProvider {
  bool linked = true;
  final targets = <AnimeRiftCommentTarget>[];
  String? posted;

  @override
  Future<bool> restoreAccountSession() async => linked;

  @override
  Future<AnimeRiftCommentPage> loadComments(
    AnimeRiftCommentTarget target, {
    int page = 0,
  }) async {
    targets.add(target);
    return const AnimeRiftCommentPage(
      items: [
        AnimeRiftComment(
          id: 'comment1',
          text: 'تعليق من ريفت',
          author: 'المستخدم',
          likes: 2,
          replies: 1,
          spoiler: false,
        ),
      ],
      hasMore: false,
    );
  }

  @override
  Future<void> publishComment(
    AnimeRiftCommentTarget target,
    String text,
  ) async {
    targets.add(target);
    posted = text;
  }
}

void main() {
  testWidgets(
    'AnimeRift anime comments show remote list and post with own account',
    (tester) async {
      final provider = FakeRiftCommentsProvider();
      await tester.pumpWidget(
        MaterialApp(
          home: AnimeRiftCommentsScreen(
            provider: provider,
            target: const AnimeRiftCommentTarget(
              animeId: 'anime42',
              title: 'أنمي',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('تعليق من ريفت'), findsOneWidget);
      expect(find.text('المستخدم'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('rift-comment-input')),
        'نصي',
      );
      await tester.tap(find.byTooltip('نشر التعليق'));
      await tester.pumpAndSettle();
      expect(provider.posted, 'نصي');
      expect(provider.targets.last.animeId, 'anime42');
    },
  );

  testWidgets('Rift episode reply screen preserves episode identity', (
    tester,
  ) async {
    final provider = FakeRiftCommentsProvider();
    await tester.pumpWidget(
      MaterialApp(
        home: AnimeRiftCommentsScreen(
          provider: provider,
          target: const AnimeRiftCommentTarget(
            animeId: 'anime42',
            episodeId: 'ep22',
            title: 'الحلقة',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('الردود 1'));
    await tester.pumpAndSettle();
    expect(provider.targets.last.animeId, 'anime42');
    expect(provider.targets.last.episodeId, 'ep22');
    expect(provider.targets.last.parentId, 'comment1');
  });

  testWidgets('guest can read comments but cannot compose as Witcher account', (
    tester,
  ) async {
    final provider = FakeRiftCommentsProvider()..linked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: AnimeRiftCommentsScreen(
          provider: provider,
          target: const AnimeRiftCommentTarget(
            animeId: 'anime42',
            title: 'أنمي',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('تعليق من ريفت'), findsOneWidget);
    expect(find.byKey(const ValueKey('rift-comment-input')), findsNothing);
    expect(find.textContaining('اربط حساب AnimeRift'), findsOneWidget);
  });
}

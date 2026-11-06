import 'dart:async';

import 'package:animewitcher/core/extensions/providers/anime_rift_comments.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/features/comments/presentation/anime_rift_comments_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRiftCommentsProvider extends AnimeRiftProvider {
  bool linked = true;
  bool failPublish = false;
  bool failReaction = false;
  Completer<void>? reactionCompletion;
  int reactionCount = 0;
  bool? termsAccepted;
  bool? replyAllowed;
  String? reactedId;
  AnimeRiftCommentTarget? reactedTarget;
  int loadCount = 0;
  final targets = <AnimeRiftCommentTarget>[];
  String? posted;

  @override
  Future<bool> restoreAccountSession() async => linked;

  @override
  Future<AnimeRiftCommentPage> loadComments(
    AnimeRiftCommentTarget target, {
    int page = 0,
  }) async {
    loadCount++;
    targets.add(target);
    return AnimeRiftCommentPage(
      termsAccepted: termsAccepted,
      replyAllowed: replyAllowed,
      items: const [
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
    if (failPublish) throw StateError('Post failed');
    posted = text;
  }

  @override
  Future<void> reactToComment(
    AnimeRiftCommentTarget target,
    String commentId,
  ) async {
    reactionCount++;
    reactedTarget = target;
    reactedId = commentId;
    if (reactionCompletion != null) await reactionCompletion!.future;
    if (failReaction) throw StateError('Reaction failed');
  }
}

class EmptyFirstPageRiftProvider extends FakeRiftCommentsProvider {
  final requestedPages = <int>[];

  @override
  Future<AnimeRiftCommentPage> loadComments(
    AnimeRiftCommentTarget target, {
    int page = 0,
  }) async {
    requestedPages.add(page);
    if (page == 0) {
      return const AnimeRiftCommentPage(items: [], hasMore: true);
    }
    return const AnimeRiftCommentPage(
      items: [
        AnimeRiftComment(
          id: 'visible-on-page-two',
          text: 'تعليق في الصفحة التالية',
          author: 'مستخدم',
          likes: 0,
          replies: 0,
          spoiler: false,
        ),
      ],
      hasMore: false,
    );
  }
}

class UnrecognizedRiftSessionProvider extends FakeRiftCommentsProvider {
  @override
  Future<AnimeRiftCommentPage> loadComments(
    AnimeRiftCommentTarget target, {
    int page = 0,
  }) async => const AnimeRiftCommentPage(
    items: [],
    hasMore: false,
    serverUserIdPresent: false,
  );
}

/// Real APK comment listing includes viewer-scoped interactions. A new
/// provider instance has no in-memory likes, just like a cold app restart.
class NativeViewerReactionProvider extends FakeRiftCommentsProvider {
  @override
  Future<AnimeRiftCommentPage> loadComments(
    AnimeRiftCommentTarget target, {
    int page = 0,
  }) async {
    loadCount++;
    return AnimeRiftCommentPage.fromJson({
      'items': [
        {
          '_id': 'comment1',
          'text': 'تعليق من ريفت',
          '_user': {'name': 'المستخدم'},
          'reactions_counts': {'thumbsUp': 3},
          'replies_count': 1,
        },
      ],
      'interaction_keys': {'like': 'LIKE_ACTION'},
      'interactions': [
        {
          '_comment': 'comment1',
          'action': 'LIKE_ACTION',
          'reaction_type': 'thumbsUp',
        },
      ],
    });
  }
}

void main() {
  testWidgets('server-origin like is shown after a fresh screen and provider', (
    tester,
  ) async {
    const target = AnimeRiftCommentTarget(animeId: 'anime42', title: 'أنمي');
    final firstProvider = NativeViewerReactionProvider();
    await tester.pumpWidget(
      MaterialApp(
        home: AnimeRiftCommentsScreen(provider: firstProvider, target: target),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    final newProvider = NativeViewerReactionProvider();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        home: AnimeRiftCommentsScreen(provider: newProvider, target: target),
      ),
    );
    await tester.pumpAndSettle();
    expect(newProvider.loadCount, 1);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    // Native PUT toggles an existing reaction off; do not add a second like.
    await tester.tap(find.byTooltip('الإعجابات'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(newProvider.reactionCount, 1);
    expect(newProvider.loadCount, 1);
  });
  testWidgets(
    'linked account is not reported as zero published comments when server omits user ID',
    (tester) async {
      final provider = UnrecognizedRiftSessionProvider();
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
      expect(find.textContaining('دون معرّف مستخدم'), findsOneWidget);
      expect(find.text('لا توجد تعليقات منشورة بعد.'), findsNothing);
    },
  );

  testWidgets('Rift does not hide later pages when the first is empty', (
    tester,
  ) async {
    final provider = EmptyFirstPageRiftProvider();
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
    expect(find.text('تعليق في الصفحة التالية'), findsOneWidget);
    expect(provider.requestedPages, [0, 1]);
  });
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
    await tester.tap(find.byTooltip('الردود'));
    await tester.pumpAndSettle();
    expect(provider.targets.last.animeId, 'anime42');
    expect(provider.targets.last.episodeId, 'ep22');
    expect(provider.targets.last.parentId, 'comment1');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(provider.loadCount, 3);
  });

  testWidgets('failed publish keeps draft and allows retry', (tester) async {
    final provider = FakeRiftCommentsProvider()..failPublish = true;
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
    const draft = 'احتفظ بالنص عند الفشل';
    await tester.enterText(
      find.byKey(const ValueKey('rift-comment-input')),
      draft,
    );
    await tester.tap(find.byTooltip('نشر التعليق'));
    await tester.pumpAndSettle();
    expect(find.text(draft), findsOneWidget);
    expect(provider.posted, isNull);
    provider.failPublish = false;
    ScaffoldMessenger.of(
      tester.element(find.byKey(const ValueKey('rift-comment-input'))),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('نشر التعليق'));
    await tester.pumpAndSettle();
    expect(provider.posted, draft);
    expect(find.text(draft), findsNothing);
  });

  testWidgets('like immediately toggles heart and count without reloading', (
    tester,
  ) async {
    final provider = FakeRiftCommentsProvider()
      ..reactionCompletion = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: AnimeRiftCommentsScreen(
          provider: provider,
          target: const AnimeRiftCommentTarget(
            animeId: 'anime42',
            episodeId: 'episode17',
            parentId: 'parent9',
            title: 'الحلقة',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('الإعجابات'));
    await tester.pumpAndSettle();
    expect(provider.reactedId, 'comment1');
    expect(provider.reactedTarget?.animeId, 'anime42');
    expect(provider.reactedTarget?.episodeId, 'episode17');
    expect(provider.reactedTarget?.parentId, 'parent9');
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('تعليق من ريفت'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.byTooltip('الإعجابات'));
    await tester.pump();
    expect(provider.reactionCount, 1);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    expect(provider.loadCount, 1);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    provider.reactionCompletion!.complete();
    await tester.pumpAndSettle();
    expect(provider.loadCount, 1);
    provider.reactionCompletion = null;
    await tester.enterText(
      find.byKey(const ValueKey('rift-comment-input')),
      'تعليق لتحديث القائمة',
    );
    await tester.tap(find.byTooltip('نشر التعليق'));
    await tester.pumpAndSettle();
    expect(provider.loadCount, 2);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.byTooltip('الإعجابات'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(provider.reactionCount, 2);
    expect(provider.loadCount, 2);
  });

  testWidgets('reaction failure shows feedback without reloading', (
    tester,
  ) async {
    final provider = FakeRiftCommentsProvider()
      ..failReaction = true
      ..reactionCompletion = Completer<void>();
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
    await tester.tap(find.byTooltip('الإعجابات'));
    await tester.pump();
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    provider.reactionCompletion!.complete();
    await tester.pumpAndSettle();
    expect(provider.loadCount, 1);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.textContaining('تعذر إكمال العملية'), findsOneWidget);
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

  testWidgets(
    'server refusal to accept guidelines blocks compose but not reading',
    (tester) async {
      final provider = FakeRiftCommentsProvider()..termsAccepted = false;
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
      expect(find.textContaining('قبول إرشادات المجتمع'), findsOneWidget);
      expect(provider.posted, isNull);
    },
  );

  testWidgets('explicit replyAllowed false disables reply composer only', (
    tester,
  ) async {
    final provider = FakeRiftCommentsProvider()..replyAllowed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: AnimeRiftCommentsScreen(
          provider: provider,
          target: const AnimeRiftCommentTarget(
            animeId: 'anime42',
            parentId: 'parent9',
            title: 'أنمي',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('تعليق من ريفت'), findsOneWidget);
    expect(find.byKey(const ValueKey('rift-comment-input')), findsNothing);
    expect(find.textContaining('لا يسمح بالرد'), findsOneWidget);
  });
}

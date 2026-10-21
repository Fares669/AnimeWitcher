import 'package:animewitcher/core/account/animewitcher_notification_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AnimeWitcherNotification item(Map<String, dynamic> fields) =>
      AnimeWitcherNotification.fromDocument(
        FirestoreDocument(
          id: 'n1',
          path: 'users/profile/notifications/n1',
          fields: fields,
        ),
      );

  test('notification keeps clicked separate from date and actor data', () {
    final date = DateTime.utc(2026, 1, 2);
    final value = item({
      'type': 'review_reply',
      'clicked': true,
      'date': date,
      'user': {'name': 'سارة', 'pic': 'https://example.com/a.png'},
      'review_doc_ref': 'anime_list/a/reviews/r',
      'anime_name': 'أنمي',
    });
    expect(value.clicked, isTrue);
    expect(value.date, date);
    expect(value.actorName, 'سارة');
    expect(value.targetPath, 'anime_list/a/reviews/r');
    expect(value.message, contains('سارة'));
    expect(value.message, contains('أنمي'));
    expect(value.copyWith(clicked: false).clicked, isFalse);
  });

  test('missing actor and unknown type render safely without repair', () {
    final value = item({'type': 'future_type'});
    expect(value.actorName, 'مستخدم');
    expect(value.message, contains('تحديث'));
    expect(value.targetPath, isNull);
  });

  test(
    'supports only parent comment/review paths, never arbitrary documents',
    () {
      for (final path in [
        'anime_list/a/comments/c',
        'anime_list/a/episodes/e/comments/c',
        'characters_list/x/comments/c',
        'news/n/comments/c',
      ]) {
        expect(
          item({'type': 'anime_comment_reply', 'comment_doc_ref': path})
              .targetPath,
          path,
        );
      }
      for (final path in [
        'users/private',
        'anime_list/a',
        'anime_list/a/comments/c/replies/r',
        '../users/x',
        'anime_list/a/comments/..',
        'https://host/anime_list/a/comments/c',
        'anime_list//comments/c',
      ]) {
        expect(
          item({'type': 'anime_comment_reply', 'comment_doc_ref': path})
              .targetPath,
          isNull,
        );
      }
      expect(
        item({'type': 'review_like', 'review_doc_ref': 'users/u/reviews/r'})
            .targetPath,
        isNull,
      );
      expect(
        item({
          'type': 'review_like',
          'review_doc_ref': 'anime_list/a/reviews/r',
          'comment_doc_ref': 'news/n/comments/c',
        }).targetPath,
        'anime_list/a/reviews/r',
      );
    },
  );

  test(
    'malformed actor fields and foreign resource references are not trusted',
    () {
      final value = item({
        'clicked': 'true',
        'date': {'seconds': 'bad'},
        'user': {'name': <String>[], 'pic': 'file:///private/avatar'},
        'type': 'review_reply',
        'review_doc_ref': 'projects/foreign/databases/(default)/documents/anime_list/a/reviews/r',
      });
      expect(value.clicked, isFalse);
      expect(value.date, isNull);
      expect(value.actorName, 'مستخدم');
      expect(value.actorPhotoUrl, isNull);
      expect(value.targetPath, isNull);
    },
  );
  test('all 20 APK notification types have specific action text', () {
    for (final prefix in [
      'review',
      'anime_comment',
      'episode_comment',
      'character_comment',
      'news_comment',
    ]) {
      for (final suffix in ['like', 'reply', 'reply_like', 'reply_tag']) {
        final value = item({
          'type': '${prefix}_$suffix',
          'user': {'name': 'فاعل'},
        });
        expect(value.message, contains('فاعل'));
        expect(value.message, isNot(contains('تحديث')));
      }
    }
  });
  test(
    'encoded-looking IDs remain literal and are never decoded as traversal',
    () {
      for (final id in ['%2e%2e', '%2F', 'title #1?']) {
        final path = 'anime_list/a/comments/$id';
        expect(
          item({'type': 'anime_comment_like', 'comment_doc_ref': path})
              .targetPath,
          path,
        );
      }
    },
  );
  test('notification ownership rejects other users and nested documents', () {
    expect(
      animeWitcherOwnsNotificationPath('users/p/notifications/n', 'p'),
      isTrue,
    );
    for (final path in [
      'users/q/notifications/n',
      'users/p/notifications/n/x/y',
      'users/p/notifications/..',
      'users/p/notifications/%2f',
      '/users/p/notifications/n',
    ]) {
      expect(animeWitcherOwnsNotificationPath(path, 'p'), isFalse);
    }
    expect(animeWitcherNotificationPageSize, 20);
  });
}

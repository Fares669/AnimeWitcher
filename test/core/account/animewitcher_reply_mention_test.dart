import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/animewitcher_reply_mention.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('applyAnimeWitcherReplyMention', () {
    test('appends @name and a trailing space for someone else', () {
      final outcome = applyAnimeWitcherReplyMention(
        currentText: '',
        currentUserTagId: null,
        replyUserId: 'user-2',
        replyUserName: 'حمزة سان',
        isOwnReply: false,
      );

      expect(outcome.status, AnimeWitcherReplyMentionStatus.applied);
      expect(outcome.text, '@حمزة سان ');
      expect(outcome.userTagId, 'user-2');
    });

    test('appends onto existing composer text', () {
      final outcome = applyAnimeWitcherReplyMention(
        currentText: 'hello',
        currentUserTagId: null,
        replyUserId: 'user-2',
        replyUserName: 'Killua',
        isOwnReply: false,
      );

      expect(outcome.text, 'hello@Killua ');
      expect(outcome.userTagId, 'user-2');
    });

    test('does nothing for your own reply', () {
      final outcome = applyAnimeWitcherReplyMention(
        currentText: 'draft',
        currentUserTagId: null,
        replyUserId: 'me',
        replyUserName: 'Me',
        isOwnReply: true,
      );

      expect(outcome.status, AnimeWitcherReplyMentionStatus.ownReply);
      expect(outcome.text, 'draft');
      expect(outcome.userTagId, isNull);
    });

    test('rejects a second tag while one is already set', () {
      final outcome = applyAnimeWitcherReplyMention(
        currentText: '@حمزة سان ',
        currentUserTagId: 'user-2',
        replyUserId: 'user-3',
        replyUserName: 'Other',
        isOwnReply: false,
      );

      expect(outcome.status, AnimeWitcherReplyMentionStatus.alreadyTagged);
      expect(outcome.text, '@حمزة سان ');
      expect(outcome.userTagId, 'user-2');
    });
  });

  group('animeWitcherReplyUserTagIdAfterTextChange', () {
    test('clears the stored tag when @ is removed', () {
      expect(
        animeWitcherReplyUserTagIdAfterTextChange(
          text: 'no mention left',
          currentUserTagId: 'user-2',
        ),
        isNull,
      );
    });

    test('keeps the stored tag while @ remains', () {
      expect(
        animeWitcherReplyUserTagIdAfterTextChange(
          text: '@حمزة سان edited',
          currentUserTagId: 'user-2',
        ),
        'user-2',
      );
    });
  });

  test('already-tagged toast matches the APK Arabic copy', () {
    expect(
      animeWitcherReplyAlreadyTaggedMessage(),
      'لا يمكن اضافة اكثر من تاج',
    );
  });

  group('animeWitcherReplyWriteFields', () {
    test('includes user_tag only when a mention is set', () {
      expect(
        animeWitcherReplyWriteFields(
          comment: '@حمزة سان انا فكرتها كيلوا',
          userId: 'me',
          userTagId: 'user-2',
        ),
        <String, dynamic>{
          'comment': '@حمزة سان انا فكرتها كيلوا',
          'likes': 0,
          'user_id': 'me',
          'user_tag': 'user-2',
        },
      );
    });

    test('omits user_tag when no mention is set', () {
      expect(
        animeWitcherReplyWriteFields(comment: 'plain reply', userId: 'me'),
        <String, dynamic>{
          'comment': 'plain reply',
          'likes': 0,
          'user_id': 'me',
        },
      );
    });
  });

  test('replies default to oldest while comments default to newest', () {
    expect(
      AnimeWitcherCommentSort.repliesDefault,
      AnimeWitcherCommentSort.oldest,
    );
    expect(
      AnimeWitcherCommentSort.commentsDefault,
      AnimeWitcherCommentSort.newest,
    );
    expect(AnimeWitcherCommentSort.oldest.descending, isFalse);
    expect(AnimeWitcherCommentSort.newest.descending, isTrue);
  });
}

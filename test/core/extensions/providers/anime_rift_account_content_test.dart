import 'package:animewitcher/core/extensions/providers/anime_rift_account_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Rift account profile reads avatar and cover from nested native fields',
    () {
      final profile = AnimeRiftAccountProfile.fromJson({
        'items': {
          'profile': {
            'userName': 'حساب ريفت',
            'avatar': {'url': 'https://cdn.example.test/avatar.png'},
            'cover': {'url': 'https://cdn.example.test/banner.jpg'},
          },
        },
      });
      expect(profile.name, 'حساب ريفت');
      expect(profile.avatarUrl, 'https://cdn.example.test/avatar.png');
      expect(profile.coverUrl, 'https://cdn.example.test/banner.jpg');
    },
  );

  test(
    'Rift account artwork rejects unsafe schemes and invalid containers',
    () {
      final profile = AnimeRiftAccountProfile.fromJson({
        'items': {
          'avatar': 'javascript:alert(1)',
          'cover': 'http://cdn.example.test/cover',
        },
      });
      expect(profile.avatarUrl, isNull);
      expect(profile.coverUrl, isNull);
      expect(
        () => AnimeRiftAccountProfile.fromJson({'items': []}),
        throwsFormatException,
      );
    },
  );

  test(
    'history retains review and spoiler labels and linked anime identity',
    () {
      final page = AnimeRiftMyCommentPage.fromJson({
        'items': [
          {
            '_id': 'comment-42',
            'comment': 'عمل ممتاز',
            'has_spoiler': true,
            'is_review': true,
            'replies_count': 2,
            '_anime': {'_id': 'anime42', 'title': 'عنوان الأنمي'},
            '_user': {'userName': 'صاحب الحساب'},
          },
        ],
        'hasNext': true,
      });
      expect(page.items, hasLength(1));
      expect(page.hasMore, isTrue);
      expect(page.items.single.comment.spoiler, isTrue);
      expect(page.items.single.comment.author, 'صاحب الحساب');
      expect(page.items.single.isReview, isTrue);
      expect(page.items.single.animeTitle, 'عنوان الأنمي');
      expect(page.items.single.animeId, 'anime42');
    },
  );

  test('malformed history never masquerades as an empty account', () {
    expect(
      () => AnimeRiftMyCommentPage.fromJson({'items': 'invalid'}),
      throwsFormatException,
    );
    expect(
      () => AnimeRiftMyCommentPage.fromJson({
        'items': [
          {'unknown': true},
        ],
      }),
      throwsFormatException,
    );
  });
}

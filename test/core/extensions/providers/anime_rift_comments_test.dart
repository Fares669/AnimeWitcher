import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_comments.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CommentClientFixture extends AnimeRiftApiClient {
  String? lastPath;
  String? lastScope;
  String? lastMethod;
  Map<String, dynamic>? lastQuery;
  String? postedText;
  String? reactedCommentId;
  Map<String, dynamic>? createdTarget;

  CommentClientFixture()
    : super(
        config: const AnimeRiftConfig(
          firebaseApiKey: 'fake',
          firebaseAppId: 'fake',
          signingKey: 'fake',
        ),
      );

  @override
  Future<Map<String, dynamic>> request(
    String path,
    String scope, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    lastPath = path;
    lastScope = scope;
    lastMethod = method;
    lastQuery = query;
    return {
      'items': [
        {
          '_id': 'comment1',
          'comment': 'النص',
          '_user': {'name': 'الكاتب'},
          'reactions_counts': {'thumbsUp': 4},
          'replies_count': 2,
        },
      ],
      'hasNext': true,
    };
  }

  @override
  Future<Map<String, dynamic>> createComment({
    required String animeId,
    String? episodeId,
    String? parentId,
    required String text,
  }) async {
    createdTarget = AnimeRiftApiClient.commentTargetFields(
      animeId: animeId,
      episodeId: episodeId,
      parentId: parentId,
    );
    postedText = text;
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> reactToComment(
    String commentId, {
    String? animeId,
    String? episodeId,
  }) async {
    reactedCommentId = commentId;
    return {'success': true};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final anime = MultimediaItem(
    title: 'Rift anime',
    posterUrl: '',
    url: 'https://anime-rift.com/anime/anime42',
    provider: animeRiftProviderId,
  );
  final episode = Episode(
    name: 'الحلقة الأولى',
    episode: 1,
    url: 'https://anime-rift.com/anime/anime42/episode/ep11',
  );

  test('Rift anime/episode targets are source and URL qualified', () {
    final animeTarget = AnimeRiftCommentTarget.forAnime(anime)!;
    expect(animeTarget.animeId, 'anime42');
    expect(animeTarget.episodeId, isNull);
    final episodeTarget = AnimeRiftCommentTarget.forEpisode(anime, episode)!;
    expect(episodeTarget.animeId, 'anime42');
    expect(episodeTarget.episodeId, 'ep11');
    expect(episodeTarget.replies('comment11').parentId, 'comment11');
    expect(
      AnimeRiftCommentTarget.forAnime(
        anime.copyWith(provider: 'com.fares669.animewitcher.native'),
      ),
      isNull,
    );
    expect(
      AnimeRiftCommentTarget.forEpisode(
        anime,
        Episode(
          name: 'foreign episode',
          episode: 3,
          url: 'https://anime-rift.com/anime/another/episode/ep11',
        ),
      ),
      isNull,
    );
  });

  test('Rift comment API target values reject invalid identifiers', () {
    expect(AnimeRiftApiClient.commentTargetFields(animeId: '42'), {
      'animeId': '42',
    });
    expect(
      AnimeRiftApiClient.commentTargetFields(
        animeId: '42',
        episodeId: 'ep1',
        parentId: 'comment1',
      ),
      {'animeId': '42', 'episodeId': 'ep1', 'parentId': 'comment1'},
    );
    expect(
      () => AnimeRiftApiClient.commentTargetFields(animeId: '../escape'),
      throwsArgumentError,
    );
  });

  test('Rift response reader preserves only valid visible comments', () {
    final page = AnimeRiftCommentPage.fromJson({
      'items': [
        {
          '_id': '1',
          'comment': 'hello',
          '_user': {'name': 'Rift user', 'accessToken': 'private-secret'},
          'reactions_counts': {'thumbsUp': 5},
          'replies_count': 2,
          'spoiler': true,
          'createdAt': '2026-11-05T08:00:00Z',
        },
        {'_id': '../invalid', 'comment': 'bad'},
        {'_id': '2', 'comment': ''},
      ],
      'hasNext': false,
    });
    expect(page.items, hasLength(1));
    expect(page.items.single.author, 'Rift user');
    expect(page.items.single.likes, 5);
    expect(page.items.single.replies, 2);
    expect(page.items.single.spoiler, isTrue);
    expect(page.items.single.toString(), isNot(contains('private-secret')));
    expect(page.hasMore, isFalse);
    expect(
      () => AnimeRiftCommentPage.fromJson({'items': <String, dynamic>{}}),
      throwsFormatException,
    );
    expect(
      () => AnimeRiftCommentPage.fromJson({
        'items': [
          {'unrecognized': 'shape'},
        ],
      }),
      throwsFormatException,
    );
  });

  test('Rift response reader accepts the live comment schema', () {
    final page = AnimeRiftCommentPage.fromJson({
      'items': [
        {
          '_id': 'fixture',
          '_user': {
            'id': 'fixture',
            'name': 'fixture',
            'user_name': 'fixture',
            'avatar': 'fixture',
            'isAdmin': false,
            'isPremium': false,
            '_id': 'fixture',
          },
          'text': 'fixture',
          'is_review': false,
          'createdAt': '2026-11-05T00:00:00Z',
          'reactions_counts': {'thumbsUp': 0},
          'replies_count': 0,
        },
      ],
    });
    expect(page.items, hasLength(1));
    expect(page.items.single.id, 'fixture');
    expect(page.items.single.text, 'fixture');
    expect(page.items.single.author, 'fixture');
    expect(page.items.single.likes, 0);
    expect(page.items.single.replies, 0);
  });

  test('native comment interactions identify the current viewer likes', () {
    final page = AnimeRiftCommentPage.fromJson({
      'items': [
        for (final id in ['liked', 'other', 'different-reaction'])
          {
            '_id': id,
            'text': 'fixture',
            'reactions_counts': {'thumbsUp': 2},
          },
      ],
      'interaction_keys': {'like': 'LIKED_ACTION'},
      'interactions': [
        {
          '_comment': 'liked',
          'action': 'LIKED_ACTION',
          'reaction_type': 'thumbsUp',
        },
        {
          '_comment': 'different-reaction',
          'action': 'LIKED_ACTION',
          'reaction_type': 'heartFace',
        },
      ],
    });
    expect(page.items.map((e) => e.likedByMe).toList(), [true, false, false]);
    expect(page.items.map((e) => e.likes).toList(), [2, 2, 2]);
    final withoutInteractionMetadata = AnimeRiftCommentPage.fromJson({
      'items': [
        {'_id': 'unknown', 'text': 'fixture'},
      ],
    });
    expect(withoutInteractionMetadata.items.single.likedByMe, isNull);
  });

  test('native default like action works without interaction_keys', () {
    final page = AnimeRiftCommentPage.fromJson({
      'items': [
        {'_id': 'liked', 'text': 'fixture'},
      ],
      'interactions': [
        {'_comment': 'liked', 'action': 'like', 'reaction_type': 'thumbsUp'},
      ],
    });
    expect(page.items.single.likedByMe, true);
  });

  test('Rift comments expose only the server account presence, never ID', () {
    final guest = AnimeRiftCommentPage.fromJson({
      'items': <Object>[],
      'userId': null,
    });
    final signedIn = AnimeRiftCommentPage.fromJson({
      'items': <Object>[],
      'userId': 'sensitive-account-id',
    });
    final unspecified = AnimeRiftCommentPage.fromJson({'items': <Object>[]});
    expect(guest.serverUserIdPresent, isFalse);
    expect(signedIn.serverUserIdPresent, isTrue);
    expect(unspecified.serverUserIdPresent, isNull);
    expect(signedIn.toString(), isNot(contains('sensitive-account-id')));
  });

  test('native comment permissions preserve explicit booleans only', () {
    final page = AnimeRiftCommentPage.fromJson({
      'items': <Object>[],
      'termsAndConditionsAccepted': true,
      'interactions': {'replyAllowed': false, 'canReplyToNext': true},
    });
    expect(page.termsAccepted, true);
    expect(page.replyAllowed, false);
    expect(page.canReplyToNext, true);

    final unknown = AnimeRiftCommentPage.fromJson({
      'items': <Object>[],
      'termsAndConditionsAccepted': 'secret',
      'replyAllowed': 1,
    });
    expect(unknown.termsAccepted, isNull);
    expect(unknown.replyAllowed, isNull);
    expect(unknown.canReplyToNext, isNull);
  });

  test(
    'Rift provider sends anime and episode comment scopes independently',
    () async {
      final client = CommentClientFixture();
      final provider = AnimeRiftProvider(client: client);
      final animeTarget = AnimeRiftCommentTarget.forAnime(anime)!;
      final animePage = await provider.loadComments(animeTarget);
      expect(animePage.items.single.text, 'النص');
      expect(client.lastPath, 'comment/all');
      expect(client.lastScope, 'COMMENTS.VIEW');
      expect(client.lastMethod, 'GET');
      expect(client.lastQuery, {
        'animeId': 'anime42',
        'page': 0,
        'level': 0,
        'canReply': '1',
        'sort_by': 'recently_added',
      });

      final episodeTarget = AnimeRiftCommentTarget.forEpisode(anime, episode)!;
      await provider.loadComments(episodeTarget.replies('comment1'), page: 2);
      expect(client.lastQuery, {
        'animeId': 'anime42',
        'episodeId': 'ep11',
        'parentId': 'comment1',
        'page': 2,
        'level': 1,
        'canReply': '1',
        'sort_by': 'recently_added',
      });
      await provider.publishComment(episodeTarget.replies('comment1'), 'reply');
      expect(client.createdTarget, {
        'animeId': 'anime42',
        'episodeId': 'ep11',
        'parentId': 'comment1',
      });
      expect(client.postedText, 'reply');
      await provider.reactToComment(episodeTarget, 'comment1');
      expect(client.reactedCommentId, 'comment1');
    },
  );

  test(
    'Rift guest cannot post to comment/create or do network writes',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await expectLater(
        AnimeRiftApiClient(
          config: const AnimeRiftConfig(),
          dio: Dio(),
        ).createComment(animeId: '42', text: 'no account'),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
    },
  );
}

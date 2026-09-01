import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

FirestoreDocument _doc({
  required String path,
  required Map<String, dynamic> fields,
}) {
  return FirestoreDocument(
    id: path.split('/').last,
    path: path,
    fields: fields,
  );
}

void main() {
  test('review write fields match AddReviewActivity', () {
    expect(
      animeWitcherReviewWriteFields(
        reviewText: 'عمل رائع',
        userId: 'user-1',
        animeId: 'jigokuraku',
      ),
      <String, dynamic>{
        'review_text': 'عمل رائع',
        'likes': 0,
        'comments': 0,
        'user_id': 'user-1',
        'anime_id': 'jigokuraku',
      },
    );
  });

  test('review documents read review_text and comments as replies', () {
    final review = AnimeWitcherComment.fromDocument(
      _doc(
        path: 'anime_list/jigokuraku/reviews/rev-1',
        fields: <String, dynamic>{
          'review_text': 'مراجعة منشورة',
          'comment': 'should not win',
          'likes': 4,
          'comments': 2,
          'user_id': 'user-1',
          'anime_id': 'jigokuraku',
          'published': true,
          'replies_closed': false,
          'user': <String, dynamic>{'name': 'فايز'},
        },
      ),
    );

    expect(review.text, 'مراجعة منشورة');
    expect(review.replies, 2);
    expect(review.likes, 4);
    expect(review.userId, 'user-1');
    expect(review.animeId, 'jigokuraku');
    expect(review.published, isTrue);
    expect(review.isReview, isTrue);
    expect(review.repliesCollectionPath, 'anime_list/jigokuraku/reviews/rev-1/replies');
  });

  test('unpublished reviews keep review_text for the author list', () {
    final review = AnimeWitcherComment.fromDocument(
      _doc(
        path: 'anime_list/jigokuraku/reviews/rev-2',
        fields: <String, dynamic>{
          'review_text': 'قيد المراجعة',
          'published': false,
          'user_id': 'user-1',
          'replies': 0,
        },
      ),
    );

    expect(review.text, 'قيد المراجعة');
    expect(review.published, isFalse);
    expect(review.replies, 0);
  });

  test('review documents ignore spoiler flags from Firestore', () {
    final review = AnimeWitcherComment.fromDocument(
      _doc(
        path: 'anime_list/jigokuraku/reviews/rev-3',
        fields: <String, dynamic>{
          'review_text': 'بدون حرق',
          'spoiler': true,
          'user_id': 'user-1',
        },
      ),
    );

    expect(review.text, 'بدون حرق');
    expect(review.isReview, isTrue);
    expect(review.spoiler, isFalse);
  });

  test('comments still read the spoiler field', () {
    final comment = AnimeWitcherComment.fromDocument(
      _doc(
        path: 'anime_list/jigokuraku/comments/c-2',
        fields: <String, dynamic>{
          'comment': 'حرق',
          'spoiler': true,
          'user_id': 'user-1',
        },
      ),
    );

    expect(comment.isReview, isFalse);
    expect(comment.spoiler, isTrue);
  });

  test('comments still read the comment field', () {
    final comment = AnimeWitcherComment.fromDocument(
      _doc(
        path: 'anime_list/jigokuraku/comments/c-1',
        fields: <String, dynamic>{
          'comment': 'تعليق',
          'review_text': 'ignored',
          'likes': 1,
          'replies': 3,
          'user_id': 'user-1',
        },
      ),
    );

    expect(comment.text, 'تعليق');
    expect(comment.replies, 3);
    expect(comment.isReview, isFalse);
  });

  test('review target points at anime_list/{id}/reviews', () {
    expect(kAnimeWitcherReviewsPageSize, 10);
    expect(animeWitcherIsReviewPath('anime_list/a/reviews/x'), isTrue);
    expect(animeWitcherIsReviewPath('anime_list/a/comments/x'), isFalse);
  });

  test('published reviews query filters published and limits to 10', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const <Map<String, dynamic>>[],
            ),
          );
        },
      ),
    );
    final client = FirestoreRestClient(dio: dio);
    await client.queryPublishedComments(
      'anime_list/naruto/reviews',
      orderField: 'date',
      descending: true,
      limit: kAnimeWitcherReviewsPageSize,
    );

    final payload = Map<String, dynamic>.from(requests.single.data as Map);
    final query = Map<String, dynamic>.from(payload['structuredQuery'] as Map);
    expect(query['from'], <Map<String, dynamic>>[
      <String, dynamic>{'collectionId': 'reviews'},
    ]);
    expect(query['limit'], 10);
    final where = Map<String, dynamic>.from(query['where'] as Map);
    final filter = Map<String, dynamic>.from(where['fieldFilter'] as Map);
    expect(filter['field'], <String, dynamic>{'fieldPath': 'published'});
    expect(filter['op'], 'EQUAL');
    expect(filter['value'], <String, dynamic>{'booleanValue': true});
    final orderBy = List<Map<String, dynamic>>.from(query['orderBy'] as List);
    expect(orderBy.first['field'], <String, dynamic>{'fieldPath': 'date'});
    expect(orderBy.first['direction'], 'DESCENDING');
  });

  test('account reviews use collectionGroup reviews by user_id', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const <Map<String, dynamic>>[],
            ),
          );
        },
      ),
    );
    final client = FirestoreRestClient(dio: dio);
    await client.queryUserReviews(
      userId: 'user-doc',
      idToken: 'id-token',
      orderField: 'likes',
      descending: true,
      limit: 10,
    );

    expect(requests.single.path, endsWith('/documents:runQuery'));
    final payload = Map<String, dynamic>.from(requests.single.data as Map);
    final query = Map<String, dynamic>.from(payload['structuredQuery'] as Map);
    expect(query['from'], <Map<String, dynamic>>[
      <String, dynamic>{
        'collectionId': 'reviews',
        'allDescendants': true,
      },
    ]);
    expect(query['limit'], 10);
    final where = Map<String, dynamic>.from(query['where'] as Map);
    final filter = Map<String, dynamic>.from(where['fieldFilter'] as Map);
    expect(filter['field'], <String, dynamic>{'fieldPath': 'user_id'});
    expect(filter['value'], <String, dynamic>{'stringValue': 'user-doc'});
    final orderBy = List<Map<String, dynamic>>.from(query['orderBy'] as List);
    expect(orderBy.first['field'], <String, dynamic>{'fieldPath': 'likes'});
  });

  test('one-review-per-user query is user_id on the reviews collection', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const <Map<String, dynamic>>[],
            ),
          );
        },
      ),
    );
    final client = FirestoreRestClient(dio: dio);
    await client.queryCommentsByUserInCollection(
      collectionPath: 'anime_list/naruto/reviews',
      userId: 'user-doc',
      idToken: 'id-token',
      limit: 1,
    );

    final payload = Map<String, dynamic>.from(requests.single.data as Map);
    final query = Map<String, dynamic>.from(payload['structuredQuery'] as Map);
    expect(query['from'], <Map<String, dynamic>>[
      <String, dynamic>{'collectionId': 'reviews'},
    ]);
    expect(query['limit'], 1);
    final where = Map<String, dynamic>.from(query['where'] as Map);
    final filter = Map<String, dynamic>.from(where['fieldFilter'] as Map);
    expect(filter['field'], <String, dynamic>{'fieldPath': 'user_id'});
  });
}

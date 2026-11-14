import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';

void main() {
  test(
    'poster batchGET uses a field mask and decodes streamed Firestore rows',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data:
                    '{"found":{"name":"projects/animewitcher-1c66d/databases/(default)/documents/anime_list/show-1","fields":{"poster":{"mapValue":{"fields":{"large":{"stringValue":"https://cdn.example/large.jpg"}}}}}}}\n'
                    '{"missing":"projects/animewitcher-1c66d/databases/(default)/documents/anime_list/show-2"}\n',
              ),
            );
          },
        ),
      );
      final client = FirestoreRestClient(dio: dio);
      final result = await client.fetchCatalogPosterFields([
        'show-1',
        'show-2',
      ], 'fixture');
      expect(requests, hasLength(1));
      expect(requests.single.path, endsWith('/documents:batchGet'));
      final body = requests.single.data as Map;
      expect((body['documents'] as List).length, 2);
      expect((body['mask'] as Map)['fieldPaths'], contains('poster'));
      expect(requests.single.headers['Authorization'], 'Bearer fixture');
      expect(
        (result['show-1']?['poster'] as Map)['large'],
        'https://cdn.example/large.jpg',
      );
      expect(result.containsKey('show-2'), isFalse);
    },
  );

  test(
    'library page bounds reads and keeps filter and tie-break cursor',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: <dynamic>[],
              ),
            );
          },
        ),
      );
      final client = FirestoreRestClient(dio: dio);
      final date = DateTime.utc(2026, 1, 1);
      await client.queryLibraryDocumentsPage(
        'users/test/user_anime',
        'fixture',
        type: 'watching',
        startAfter: FirestoreDocument(
          id: 'a',
          path: 'users/test/user_anime/a',
          fields: {'date': date},
        ),
      );
      expect(requests, hasLength(1));
      final query = (requests.single.data as Map)['structuredQuery'] as Map;
      expect(query['limit'], 30);
      expect(query['where'], {
        'fieldFilter': {
          'field': {'fieldPath': 'type'},
          'op': 'EQUAL',
          'value': {'stringValue': 'watching'},
        },
      });
      expect((query['orderBy'] as List).last, {
        'field': {'fieldPath': '__name__'},
        'direction': 'DESCENDING',
      });
      expect((query['startAt'] as Map)['before'], false);
      expect(((query['startAt'] as Map)['values'] as List).first, {
        'timestampValue': date.toIso8601String(),
      });
      expect(
        ((query['startAt'] as Map)['values'] as List).last['referenceValue'],
        endsWith('/users/test/user_anime/a'),
      );
    },
  );

  test(
    'library total uses matching server aggregation without page limit',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: [
                  {
                    'result': {
                      'aggregateFields': {
                        'total': {'integerValue': '73'},
                      },
                    },
                  },
                ],
              ),
            );
          },
        ),
      );
      final count = await FirestoreRestClient(dio: dio).countLibraryDocuments(
        'users/test/user_manga',
        'fixture',
        type: 'completed',
      );
      expect(count, 73);
      expect(requests, hasLength(1));
      expect(requests.single.path, endsWith('/users/test:runAggregationQuery'));
      final aggregation =
          (requests.single.data as Map)['structuredAggregationQuery'] as Map;
      final query = aggregation['structuredQuery'] as Map;
      expect(query.containsKey('limit'), false);
      expect(((query['where'] as Map)['fieldFilter'] as Map)['value'], {
        'stringValue': 'completed',
      });
      expect(aggregation['aggregations'], [
        {'alias': 'total', 'count': <String, dynamic>{}},
      ]);
    },
  );
}

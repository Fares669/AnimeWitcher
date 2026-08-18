import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/account/firestore_rest_client.dart';

void main() {
  test('related anime uses one public Firestore IN query', () async {
    final dio = Dio();
    final requests = <RequestOptions>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: const <Map<String, dynamic>>[
                <String, dynamic>{
                  'document': <String, dynamic>{
                    'name':
                        'projects/animewitcher-1c66d/databases/(default)'
                        '/documents/anime_list/related-show',
                    'fields': <String, dynamic>{
                      'mal_id': <String, dynamic>{'stringValue': '5'},
                      'name': <String, dynamic>{
                        'stringValue': 'Related Show',
                      },
                    },
                  },
                },
              ],
            ),
          );
        },
      ),
    );
    final client = FirestoreRestClient(dio: dio);

    final documents = await client.queryByStringValues(
      collectionId: 'anime_list',
      field: 'mal_id',
      values: const <String>['5', '4037', '5'],
    );

    expect(requests, hasLength(1));
    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.path, endsWith('/documents:runQuery'));
    expect(request.headers.containsKey('Authorization'), isFalse);

    final payload = Map<String, dynamic>.from(request.data as Map);
    final query = Map<String, dynamic>.from(
      payload['structuredQuery'] as Map,
    );
    expect(query, isNot(contains('limit')));
    expect(query['from'], <Map<String, dynamic>>[
      <String, dynamic>{'collectionId': 'anime_list'},
    ]);
    final where = Map<String, dynamic>.from(query['where'] as Map);
    final filter = Map<String, dynamic>.from(where['fieldFilter'] as Map);
    expect(filter['field'], <String, dynamic>{'fieldPath': 'mal_id'});
    expect(filter['op'], 'IN');
    expect(filter['value'], <String, dynamic>{
      'arrayValue': <String, dynamic>{
        'values': <Map<String, dynamic>>[
          <String, dynamic>{'stringValue': '5'},
          <String, dynamic>{'stringValue': '4037'},
        ],
      },
    });

    expect(documents, hasLength(1));
    expect(documents.single.id, 'related-show');
    expect(documents.single.fields['mal_id'], '5');
  });
}

import 'dart:convert';

import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('favorite characters page queries users/{id}/fav_characters by date',
      () async {
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
              data: const <Map<String, dynamic>>[
                <String, dynamic>{
                  'document': <String, dynamic>{
                    'name':
                        'projects/animewitcher-1c66d/databases/(default)'
                        '/documents/users/user-1/fav_characters/417',
                    'fields': <String, dynamic>{
                      'mal_id': <String, dynamic>{'stringValue': '417'},
                      'name': <String, dynamic>{'stringValue': 'Lelouch'},
                      'likes': <String, dynamic>{'integerValue': '12'},
                      'date': <String, dynamic>{
                        'timestampValue': '2026-01-01T00:00:00Z',
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
    final documents = await client.queryOrderedDocumentsPage(
      'users/user-1/fav_characters',
      'id-token',
      limit: 12,
    );

    expect(documents, hasLength(1));
    expect(documents.single.id, '417');
    final request = requests.single;
    expect(request.method, 'POST');
    expect(
      request.path,
      endsWith('/documents/users/user-1:runQuery'),
    );
    expect(request.headers['Authorization'], 'Bearer id-token');
    final payload = Map<String, dynamic>.from(request.data as Map);
    final query = Map<String, dynamic>.from(payload['structuredQuery'] as Map);
    expect(query['from'], <Map<String, dynamic>>[
      <String, dynamic>{'collectionId': 'fav_characters'},
    ]);
    expect(query['limit'], 12);
    final order = List<Map<String, dynamic>>.from(query['orderBy'] as List);
    expect(order.first['field'], <String, dynamic>{'fieldPath': 'date'});
    expect(order.first['direction'], 'DESCENDING');
  });

  test('adding a favorite character merges mal_id and a server timestamp',
      () async {
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
              data: const <String, dynamic>{},
            ),
          );
        },
      ),
    );
    final client = FirestoreRestClient(dio: dio);
    await client.setDocumentWithServerTimestamps(
      'users/user-1/fav_characters/417',
      const <String, dynamic>{'mal_id': '417'},
      'id-token',
      serverTimestampFields: const <String>{'date'},
      merge: true,
    );

    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.path, endsWith('/documents:commit'));
    final payload = Map<String, dynamic>.from(request.data as Map);
    final write = Map<String, dynamic>.from(
      (payload['writes'] as List).single as Map,
    );
    final update = Map<String, dynamic>.from(write['update'] as Map);
    expect(
      update['name'],
      contains('users/user-1/fav_characters/417'),
    );
    expect(update['fields'], <String, dynamic>{
      'mal_id': <String, dynamic>{'stringValue': '417'},
    });
    expect(write['updateMask'], <String, dynamic>{
      'fieldPaths': <String>['mal_id'],
    });
    expect(write['updateTransforms'], <Map<String, dynamic>>[
      <String, dynamic>{
        'fieldPath': 'date',
        'setToServerValue': 'REQUEST_TIME',
      },
    ]);
    expect(jsonEncode(payload), isNot(contains('increment')));
  });

  test('removing a favorite character deletes the fav doc', () async {
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
              data: const <String, dynamic>{},
            ),
          );
        },
      ),
    );
    final client = FirestoreRestClient(dio: dio);
    await client.deleteDocument(
      'users/user-1/fav_characters/417',
      'id-token',
    );

    expect(requests.single.method, 'DELETE');
    expect(
      requests.single.path,
      endsWith('/documents/users/user-1/fav_characters/417'),
    );
  });
}

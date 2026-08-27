import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('patchDocument sends nested Firestore fields for dotted update masks',
      () async {
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
              data: const <String, dynamic>{},
            ),
          );
        },
      ),
    );
    final client = FirestoreRestClient(dio: dio);

    await client.patchDocument(
      'users/profile-1',
      const <String, dynamic>{
        'settings.show_fav_to_users': false,
        'settings.show_comments_to_users': false,
        'settings.show_reviews_to_users': false,
        'settings.hide_ecchi_anime': true,
      },
      'id-token',
      requireExisting: true,
    );

    final request = requests.single;
    expect(request.method, 'PATCH');
    expect(request.queryParameters['currentDocument.exists'], isTrue);
    expect(request.queryParameters['updateMask.fieldPaths'], <String>[
      'settings.hide_ecchi_anime',
      'settings.show_comments_to_users',
      'settings.show_fav_to_users',
      'settings.show_reviews_to_users',
    ]);
    final payload = Map<String, dynamic>.from(request.data as Map);
    expect(payload['fields'], <String, dynamic>{
      'settings': <String, dynamic>{
        'mapValue': <String, dynamic>{
          'fields': <String, dynamic>{
            'show_fav_to_users': <String, dynamic>{'booleanValue': false},
            'show_comments_to_users': <String, dynamic>{
              'booleanValue': false,
            },
            'show_reviews_to_users': <String, dynamic>{
              'booleanValue': false,
            },
            'hide_ecchi_anime': <String, dynamic>{'booleanValue': true},
          },
        },
      },
    });
  });
}

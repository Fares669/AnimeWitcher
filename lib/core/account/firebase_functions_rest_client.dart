import 'package:dio/dio.dart';

import 'animewitcher_account_config.dart';
import 'animewitcher_account_models.dart';

class FirebaseFunctionsRestClient {
  FirebaseFunctionsRestClient({Dio? dio})
    : _dio = dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 20),
              headers: const <String, String>{'Accept': 'application/json'},
            ),
          );

  final Dio _dio;

  Future<void> syncNewAuthEmailToFirestore(String idToken) async {
    final region = AnimeWitcherAccountConfig.functionsRegion.trim();
    final project = AnimeWitcherAccountConfig.projectId.trim();
    if (region.isEmpty || project.isEmpty) return;
    try {
      await _dio.post<dynamic>(
        'https://$region-$project.cloudfunctions.net/'
        'syncNewAuthEmailToFirestore',
        data: const <String, dynamic>{'data': null},
        options: Options(
          contentType: Headers.jsonContentType,
          headers: <String, String>{'Authorization': 'Bearer $idToken'},
        ),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        throw const AnimeWitcherAccountException(
          'invalid-session',
          'The account session has expired. Please sign in again.',
        );
      }
      throw AnimeWitcherAccountException(
        'email-sync-failed',
        error.message ?? 'The account email could not be synchronized.',
      );
    }
  }
}

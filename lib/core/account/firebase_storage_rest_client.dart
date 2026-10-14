import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'animewitcher_account_config.dart';
import 'animewitcher_account_models.dart';

/// Minimal Firebase Storage client used by AnimeWitcher account images.
///
/// This intentionally mirrors the Firebase Storage multipart wire protocol so
/// iOS keeps using REST and does not need Firebase Core/Storage initialization.
class FirebaseStorageRestClient {
  FirebaseStorageRestClient({Dio? dio, String? storageBucket})
    : _storageBucket =
          storageBucket ?? AnimeWitcherAccountConfig.storageBucket,
      _dio = dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 45),
              sendTimeout: const Duration(seconds: 45),
              headers: const <String, String>{'Accept': 'application/json'},
            ),
          );

  final Dio _dio;
  final String _storageBucket;

  String get _bucketBase =>
      'https://firebasestorage.googleapis.com/v0/b/'
      '${Uri.encodeComponent(_storageBucket)}/o';

  Future<String> uploadAccountImage({
    required String idToken,
    required String documentId,
    required AnimeWitcherProfileImageKind kind,
    required Uint8List bytes,
  }) async {
    if (_storageBucket.trim().isEmpty) {
      throw const AnimeWitcherAccountException(
        'storage-not-configured',
        'AnimeWitcher profile image storage is not configured.',
      );
    }
    if (bytes.isEmpty) {
      throw const AnimeWitcherAccountException(
        'invalid-image',
        'Choose a valid image.',
      );
    }

    final prefix = kind == AnimeWitcherProfileImageKind.avatar
        ? 'profile_image'
        : 'cover_image';
    final objectPath =
        'users_ver2/$documentId/${prefix}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final boundary = _multipartBoundary();
    final metadata = jsonEncode(<String, dynamic>{
      'name': objectPath,
      'contentType': 'image/jpeg',
    });
    final body = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=utf-8\r\n\r\n'
          '$metadata\r\n'
          '--$boundary\r\n'
          'Content-Type: image/jpeg\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--'));

    try {
      final response = await _dio.post<dynamic>(
        _bucketBase,
        queryParameters: <String, dynamic>{'name': objectPath},
        data: body.takeBytes(),
        options: Options(
          contentType: 'multipart/related; boundary=$boundary',
          headers: <String, String>{
            'Authorization': 'Firebase $idToken',
            'X-Goog-Upload-Protocol': 'multipart',
          },
        ),
      );
      var metadataPayload = _asMap(response.data);
      var token = _downloadToken(metadataPayload['downloadTokens']);
      if (token == null) {
        final metadataResponse = await _dio.get<dynamic>(
          '$_bucketBase/${Uri.encodeComponent(objectPath)}',
          options: Options(
            contentType: Headers.jsonContentType,
            headers: <String, String>{
              'Authorization': 'Firebase $idToken',
            },
          ),
        );
        metadataPayload = _asMap(metadataResponse.data);
        token = _downloadToken(metadataPayload['downloadTokens']);
      }
      if (token == null) {
        throw const AnimeWitcherAccountException(
          'image-download-url-missing',
          'The profile image was uploaded but no download URL was returned.',
        );
      }
      return '$_bucketBase/${Uri.encodeComponent(objectPath)}'
          '?alt=media&token=${Uri.encodeQueryComponent(token)}';
    } on AnimeWitcherAccountException {
      rethrow;
    } on DioException catch (error) {
      throw _storageException(error);
    }
  }
}

String _multipartBoundary() {
  final random = Random.secure();
  final suffix = List<int>.generate(12, (_) => random.nextInt(256))
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'animewitcher-${DateTime.now().microsecondsSinceEpoch}-$suffix';
}

String? _downloadToken(dynamic raw) {
  final value = switch (raw) {
    String value => value,
    Iterable<dynamic> values when values.isNotEmpty => values.first.toString(),
    _ => '',
  };
  final token = value.split(',').first.trim();
  return token.isEmpty ? null : token;
}

Map<String, dynamic> _asMap(dynamic raw) {
  if (raw is String) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return <String, dynamic>{};
}

AnimeWitcherAccountException _storageException(DioException error) {
  final response = _asMap(error.response?.data);
  final nested = _asMap(response['error']);
  final message = (nested['message'] ?? error.message ?? '').toString();
  return switch (error.response?.statusCode) {
    401 => const AnimeWitcherAccountException(
      'invalid-session',
      'The account session has expired. Please sign in again.',
    ),
    403 => const AnimeWitcherAccountException(
      'storage-permission-denied',
      'AnimeWitcher rejected the profile image upload.',
    ),
    413 => const AnimeWitcherAccountException(
      'image-too-large',
      'The selected image is too large.',
    ),
    _ => AnimeWitcherAccountException(
      'image-upload-failed',
      message.isEmpty ? 'The profile image could not be uploaded.' : message,
    ),
  };
}

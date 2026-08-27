import 'dart:math';

import 'package:dio/dio.dart';

import 'animewitcher_account_config.dart';
import 'animewitcher_account_models.dart';

class FirestoreReference {
  const FirestoreReference(this.path);

  final String path;
}

class FirestoreDocument {
  const FirestoreDocument({
    required this.id,
    required this.path,
    required this.fields,
  });

  final String id;
  final String path;
  final Map<String, dynamic> fields;
}

class FirestoreValueCodec {
  const FirestoreValueCodec._();

  static Map<String, dynamic> encode(dynamic value) {
    if (value == null) return <String, dynamic>{'nullValue': null};
    if (value is FirestoreReference) {
      return <String, dynamic>{
        'referenceValue':
            'projects/${AnimeWitcherAccountConfig.projectId}'
            '/databases/(default)/documents/${value.path}',
      };
    }
    if (value is DateTime) {
      return <String, dynamic>{
        'timestampValue': value.toUtc().toIso8601String(),
      };
    }
    if (value is bool) return <String, dynamic>{'booleanValue': value};
    if (value is int) {
      return <String, dynamic>{'integerValue': value.toString()};
    }
    if (value is double) return <String, dynamic>{'doubleValue': value};
    if (value is num) {
      return <String, dynamic>{'doubleValue': value.toDouble()};
    }
    if (value is Iterable) {
      return <String, dynamic>{
        'arrayValue': <String, dynamic>{
          'values': value.map(encode).toList(growable: false),
        },
      };
    }
    if (value is Map) {
      final fields = <String, dynamic>{};
      value.forEach((dynamic key, dynamic nested) {
        fields[key.toString()] = encode(nested);
      });
      return <String, dynamic>{
        'mapValue': <String, dynamic>{'fields': fields},
      };
    }
    return <String, dynamic>{'stringValue': value.toString()};
  }

  static dynamic decode(dynamic raw) {
    if (raw is! Map) return null;
    final value = Map<String, dynamic>.from(raw);
    if (value.containsKey('nullValue')) return null;
    if (value.containsKey('stringValue')) return value['stringValue'] as String?;
    if (value.containsKey('booleanValue')) return value['booleanValue'] == true;
    if (value.containsKey('integerValue')) {
      return int.tryParse(value['integerValue'].toString()) ?? 0;
    }
    if (value.containsKey('doubleValue')) {
      final number = value['doubleValue'];
      return number is num
          ? number.toDouble()
          : double.tryParse(number.toString());
    }
    if (value.containsKey('timestampValue')) {
      return DateTime.tryParse(value['timestampValue'].toString());
    }
    if (value.containsKey('referenceValue')) {
      final reference = value['referenceValue'].toString();
      const marker = '/documents/';
      final markerIndex = reference.indexOf(marker);
      return markerIndex < 0
          ? reference
          : reference.substring(markerIndex + marker.length);
    }
    if (value.containsKey('arrayValue')) {
      final array = _map(value['arrayValue']);
      final values = array['values'];
      if (values is! List) return <dynamic>[];
      return values.map(decode).toList(growable: false);
    }
    if (value.containsKey('mapValue')) {
      return decodeFields(_map(_map(value['mapValue'])['fields']));
    }
    return null;
  }

  static Map<String, dynamic> encodeFields(Map<String, dynamic> fields) {
    return fields.map<String, dynamic>(
      (key, value) => MapEntry(key, encode(value)),
    );
  }

  static Map<String, dynamic> decodeFields(Map<String, dynamic> fields) {
    return fields.map<String, dynamic>(
      (key, value) => MapEntry(key, decode(value)),
    );
  }
}

class FirestoreRestClient {
  FirestoreRestClient({Dio? dio})
    : _dio = dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 25),
              sendTimeout: const Duration(seconds: 25),
              headers: const <String, String>{'Accept': 'application/json'},
            ),
          );

  final Dio _dio;
  final Map<String, int> _catalogDurationCache = <String, int>{};

  String get _databaseBase =>
      'https://firestore.googleapis.com/v1/projects/'
      '${AnimeWitcherAccountConfig.projectId}/databases/(default)';

  String get _documentsBase =>
      '$_databaseBase/documents';

  String _documentResource(String path) =>
      'projects/${AnimeWitcherAccountConfig.projectId}'
      '/databases/(default)/documents/$path';

  Future<FirestoreDocument?> getDocument(
    String path,
    String idToken,
  ) async {

    try {
      final response = await _dio.get<dynamic>(
        '$_documentsBase/${_encodedPath(path)}',
        options: _options(idToken),
      );
      final document = _decodeDocument(response.data);
      return document == null
          ? null
          : await _hydrateContinueWatchingDocument(document, idToken);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      throw _firestoreException(error);
    }
  }

  Future<List<FirestoreDocument>> listDocuments(
    String collectionPath,
    String idToken, {
    int pageSize = 100,
  }) async {

    final output = <FirestoreDocument>[];
    String? pageToken;
    do {
      try {
        final response = await _dio.get<dynamic>(
          '$_documentsBase/${_encodedPath(collectionPath)}',
          queryParameters: <String, dynamic>{
            'pageSize': pageSize,
            if (pageToken != null) 'pageToken': pageToken,
          },
          options: _options(idToken),
        );
        final payload = _map(response.data);
        final documents = payload['documents'];
        if (documents is List) {
          for (final raw in documents) {
            final document = _decodeDocument(raw);
            if (document != null) {
              output.add(
                await _hydrateContinueWatchingDocument(document, idToken),
              );
            }
          }
        }
        pageToken = _optionalString(payload['nextPageToken']);
      } on DioException catch (error) {
        if (error.response?.statusCode == 404) return output;
        throw _firestoreException(error);
      }
    } while (pageToken != null);
    return output;
  }

  /// Fetches documents in the same order as AnimeWitcher: newest first by `date`.
  /// Pagination stays server-side so the app never sorts/reverses the result.
  Future<List<FirestoreDocument>> queryOrderedDocuments(
    String collectionPath,
    String idToken, {
    String orderField = 'date',
    bool descending = true,
    int pageSize = 100,
  }) async {
    final normalized = collectionPath.replaceFirst(RegExp(r'/+$'), '');
    final segments = normalized
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) return const <FirestoreDocument>[];
    final collectionId = segments.removeLast();
    final parentPath = segments.join('/');
    final endpoint = parentPath.isEmpty
        ? '$_documentsBase:runQuery'
        : '$_documentsBase/${_encodedPath(parentPath)}:runQuery';
    final output = <FirestoreDocument>[];
    FirestoreDocument? lastDocument;
    final batchSize = pageSize.clamp(1, 100);

    while (true) {
      final structuredQuery = <String, dynamic>{
        'from': <Map<String, dynamic>>[
          <String, dynamic>{'collectionId': collectionId},
        ],
        'orderBy': <Map<String, dynamic>>[
          <String, dynamic>{
            'field': <String, dynamic>{'fieldPath': orderField},
            'direction': descending ? 'DESCENDING' : 'ASCENDING',
          },
          <String, dynamic>{
            'field': <String, dynamic>{'fieldPath': '__name__'},
            'direction': descending ? 'DESCENDING' : 'ASCENDING',
          },
        ],
        if (lastDocument != null)
          'startAt': <String, dynamic>{
            'values': <Map<String, dynamic>>[
              FirestoreValueCodec.encode(lastDocument.fields[orderField]),
              FirestoreValueCodec.encode(FirestoreReference(lastDocument.path)),
            ],
            'before': false,
          },
        'limit': batchSize,
      };

      try {
        final response = await _dio.post<dynamic>(
          endpoint,
          data: <String, dynamic>{'structuredQuery': structuredQuery},
          options: _options(idToken),
        );
        final page = _decodeRunQueryDocuments(response.data);
        if (page.isEmpty) break;
        output.addAll(page);
        if (page.length < batchSize) break;
        final next = page.last;
        if (lastDocument?.path == next.path) break;
        lastDocument = next;
      } on DioException catch (error) {
        throw _firestoreException(error);
      }
    }
    return output;
  }

  Future<List<FirestoreDocument>> queryByStringField({
    required String collectionId,
    required String field,
    required String value,
    required String idToken,
    int limit = 20,
  }) async {

    try {
      final response = await _dio.post<dynamic>(
        '$_documentsBase:runQuery',
        data: <String, dynamic>{
          'structuredQuery': <String, dynamic>{
            'from': <Map<String, dynamic>>[
              <String, dynamic>{'collectionId': collectionId},
            ],
            'where': <String, dynamic>{
              'fieldFilter': <String, dynamic>{
                'field': <String, dynamic>{'fieldPath': field},
                'op': 'EQUAL',
                'value': FirestoreValueCodec.encode(value),
              },
            },
            'limit': limit,
          },
        },
        options: _options(idToken),
      );
      final values = response.data;
      if (values is! List) return const <FirestoreDocument>[];
      final output = <FirestoreDocument>[];
      for (final raw in values) {
        final result = _map(raw);
        final document = _decodeDocument(result['document']);
        if (document != null) output.add(document);
      }
      return output;
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  /// Mirrors Firestore's `whereIn` query used by AnimeWitcher's Related tab.
  ///
  /// AnimeWitcher stores `anime_list.mal_id` as a string even though the
  /// relation objects contain numeric IDs. Keep the values encoded as strings
  /// and cap the batch at the same ten items shown by the official app.
  Future<List<FirestoreDocument>> queryByStringValues({
    required String collectionId,
    required String field,
    required Iterable<String> values,
  }) async {
    final normalizedValues = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .take(10)
        .toList(growable: false);
    if (normalizedValues.isEmpty) {
      return const <FirestoreDocument>[];
    }

    try {
      final response = await _dio.post<dynamic>(
        '$_documentsBase:runQuery',
        data: <String, dynamic>{
          'structuredQuery': <String, dynamic>{
            'from': <Map<String, dynamic>>[
              <String, dynamic>{'collectionId': collectionId},
            ],
            'where': <String, dynamic>{
              'fieldFilter': <String, dynamic>{
                'field': <String, dynamic>{'fieldPath': field},
                'op': 'IN',
                'value': FirestoreValueCodec.encode(normalizedValues),
              },
            },
          },
        },
        options: _publicOptions(),
      );
      return _decodeRunQueryDocuments(response.data);
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  Future<List<FirestoreDocument>> queryPublishedComments(
    String collectionPath, {
    String orderField = 'date',
    bool descending = true,
    FirestoreDocument? startAfter,
    int limit = 20,
  }) {
    return _querySocialDocuments(
      collectionPath: collectionPath,
      orderField: orderField,
      descending: descending,
      publishedOnly: true,
      startAfter: startAfter,
      limit: limit,
    );
  }

  Future<List<FirestoreDocument>> queryReplies(
    String collectionPath, {
    String orderField = 'date',
    bool descending = true,
    FirestoreDocument? startAfter,
    int limit = 20,
  }) {
    return _querySocialDocuments(
      collectionPath: collectionPath,
      orderField: orderField,
      descending: descending,
      publishedOnly: false,
      startAfter: startAfter,
      limit: limit,
    );
  }

  Future<List<FirestoreDocument>> _querySocialDocuments({
    required String collectionPath,
    required String orderField,
    required bool descending,
    required bool publishedOnly,
    required FirestoreDocument? startAfter,
    required int limit,
  }) async {

    final normalized = collectionPath.replaceFirst(RegExp(r'/+$'), '');
    final segments = normalized
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) return const <FirestoreDocument>[];
    final collectionId = segments.removeLast();
    final parentPath = segments.join('/');
    final endpoint = parentPath.isEmpty
        ? '$_documentsBase:runQuery'
        : '$_documentsBase/${_encodedPath(parentPath)}:runQuery';
    final structuredQuery = <String, dynamic>{
      'from': <Map<String, dynamic>>[
        <String, dynamic>{'collectionId': collectionId},
      ],
      if (publishedOnly)
        'where': <String, dynamic>{
          'fieldFilter': <String, dynamic>{
            'field': <String, dynamic>{'fieldPath': 'published'},
            'op': 'EQUAL',
            'value': FirestoreValueCodec.encode(true),
          },
        },
      'orderBy': <Map<String, dynamic>>[
        <String, dynamic>{
          'field': <String, dynamic>{'fieldPath': orderField},
          'direction': descending ? 'DESCENDING' : 'ASCENDING',
        },
        <String, dynamic>{
          'field': <String, dynamic>{'fieldPath': '__name__'},
          'direction': descending ? 'DESCENDING' : 'ASCENDING',
        },
      ],
      if (startAfter != null)
        'startAt': <String, dynamic>{
          'values': <Map<String, dynamic>>[
            FirestoreValueCodec.encode(startAfter.fields[orderField]),
            FirestoreValueCodec.encode(FirestoreReference(startAfter.path)),
          ],
          // StructuredQuery.Cursor.before=false means start after this
          // position, matching Query.startAfter(DocumentSnapshot).
          'before': false,
        },
      'limit': limit.clamp(1, 100),
    };
    try {
      final response = await _dio.post<dynamic>(
        endpoint,
        data: <String, dynamic>{'structuredQuery': structuredQuery},
        options: _publicOptions(),
      );
      return _decodeRunQueryDocuments(response.data);
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  Future<List<FirestoreDocument>> queryCommentsByUserInCollection({
    required String collectionPath,
    required String userId,
    required String idToken,
    int limit = 20,
  }) async {

    final normalized = collectionPath.replaceFirst(RegExp(r'/+$'), '');
    final segments = normalized.split('/').where((segment) => segment.isNotEmpty).toList();
    if (segments.isEmpty) return const <FirestoreDocument>[];
    final collectionId = segments.removeLast();
    final parentPath = segments.join('/');
    final endpoint = parentPath.isEmpty
        ? '$_documentsBase:runQuery'
        : '$_documentsBase/${_encodedPath(parentPath)}:runQuery';
    try {
      final response = await _dio.post<dynamic>(
        endpoint,
        data: <String, dynamic>{
          'structuredQuery': <String, dynamic>{
            'from': <Map<String, dynamic>>[
              <String, dynamic>{'collectionId': collectionId},
            ],
            'where': <String, dynamic>{
              'fieldFilter': <String, dynamic>{
                'field': <String, dynamic>{'fieldPath': 'user_id'},
                'op': 'EQUAL',
                'value': FirestoreValueCodec.encode(userId),
              },
            },
            'limit': limit.clamp(1, 100),
          },
        },
        options: _options(idToken),
      );
      return _decodeRunQueryDocuments(response.data);
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  /// Mirrors AnimeWitcher's collectionGroup("comments") account query.
  /// Unlike public comment lists, this intentionally does not filter by the
  /// `published` field so the author can also see comments under review.
  Future<List<FirestoreDocument>> queryUserComments({
    required String userId,
    required String idToken,
    String orderField = 'date',
    bool descending = true,
    FirestoreDocument? startAfter,
    int limit = 20,
  }) async {
    final direction = descending ? 'DESCENDING' : 'ASCENDING';
    final structuredQuery = <String, dynamic>{
      'from': <Map<String, dynamic>>[
        <String, dynamic>{
          'collectionId': 'comments',
          'allDescendants': true,
        },
      ],
      'where': <String, dynamic>{
        'fieldFilter': <String, dynamic>{
          'field': <String, dynamic>{'fieldPath': 'user_id'},
          'op': 'EQUAL',
          'value': FirestoreValueCodec.encode(userId),
        },
      },
      'orderBy': <Map<String, dynamic>>[
        <String, dynamic>{
          'field': <String, dynamic>{'fieldPath': orderField},
          'direction': direction,
        },
        <String, dynamic>{
          'field': <String, dynamic>{'fieldPath': '__name__'},
          'direction': direction,
        },
      ],
      if (startAfter != null)
        'startAt': <String, dynamic>{
          'values': <Map<String, dynamic>>[
            FirestoreValueCodec.encode(startAfter.fields[orderField]),
            FirestoreValueCodec.encode(FirestoreReference(startAfter.path)),
          ],
          'before': false,
        },
      'limit': limit.clamp(1, 100),
    };
    try {
      final response = await _dio.post<dynamic>(
        '$_documentsBase:runQuery',
        data: <String, dynamic>{'structuredQuery': structuredQuery},
        options: _options(idToken),
      );
      return _decodeRunQueryDocuments(response.data);
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  Future<FirestoreDocument?> latestCommentByUser({
    required String userId,
    required String idToken,
  }) async {

    try {
      final response = await _dio.post<dynamic>(
        '$_documentsBase:runQuery',
        data: <String, dynamic>{
          'structuredQuery': <String, dynamic>{
            'from': <Map<String, dynamic>>[
              <String, dynamic>{
                'collectionId': 'comments',
                'allDescendants': true,
              },
            ],
            'where': <String, dynamic>{
              'fieldFilter': <String, dynamic>{
                'field': <String, dynamic>{'fieldPath': 'user_id'},
                'op': 'EQUAL',
                'value': FirestoreValueCodec.encode(userId),
              },
            },
            'orderBy': <Map<String, dynamic>>[
              <String, dynamic>{
                'field': <String, dynamic>{'fieldPath': 'date'},
                'direction': 'DESCENDING',
              },
            ],
            'limit': 1,
          },
        },
        options: _options(idToken),
      );
      final documents = _decodeRunQueryDocuments(response.data);
      return documents.isEmpty ? null : documents.first;
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  Future<FirestoreDocument?> latestReplyByUser({
    required String userId,
    required String idToken,
  }) async {

    try {
      final response = await _dio.post<dynamic>(
        '$_documentsBase:runQuery',
        data: <String, dynamic>{
          'structuredQuery': <String, dynamic>{
            'from': <Map<String, dynamic>>[
              <String, dynamic>{
                'collectionId': 'replies',
                'allDescendants': true,
              },
            ],
            'where': <String, dynamic>{
              'fieldFilter': <String, dynamic>{
                'field': <String, dynamic>{'fieldPath': 'user_id'},
                'op': 'EQUAL',
                'value': FirestoreValueCodec.encode(userId),
              },
            },
            'orderBy': <Map<String, dynamic>>[
              <String, dynamic>{
                'field': <String, dynamic>{'fieldPath': 'date'},
                'direction': 'DESCENDING',
              },
            ],
            'limit': 1,
          },
        },
        options: _options(idToken),
      );
      final documents = _decodeRunQueryDocuments(response.data);
      return documents.isEmpty ? null : documents.first;
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  Future<FirestoreDocument> createDocument(
    String collectionPath,
    Map<String, dynamic> fields,
    String idToken,
  ) {
    final normalized = collectionPath.replaceFirst(RegExp(r'/+$'), '');
    final documentId = _randomFirestoreDocumentId();
    return setDocument(
      '$normalized/$documentId',
      fields,
      idToken,
      merge: false,
    );
  }

  Future<FirestoreDocument> setDocument(
    String path,
    Map<String, dynamic> fields,
    String idToken, {
    bool merge = true,
  }) async {

    try {
      final response = await _dio.patch<dynamic>(
        '$_documentsBase/${_encodedPath(path)}',
        queryParameters: merge
            ? <String, dynamic>{
                'updateMask.fieldPaths': fields.keys.toList(growable: false),
              }
            : null,
        data: <String, dynamic>{
          'fields': FirestoreValueCodec.encodeFields(fields),
        },
        options: _options(idToken),
      );
      final document = _decodeDocument(response.data);
      if (document == null) {
        throw const AnimeWitcherAccountException(
          'invalid-firestore-response',
          'The sync server returned an invalid document.',
        );
      }
      return document;
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  /// Updates selected fields and can delete others in the same Firestore PATCH.
  /// A field present in updateMask but omitted from the document is deleted,
  /// which is the REST equivalent of FieldValue.delete().
  Future<void> patchDocument(
    String path,
    Map<String, dynamic> fields,
    String idToken, {
    Set<String> deleteFields = const <String>{},
    bool requireExisting = false,
  }) async {
    final overlap = fields.keys.toSet().intersection(deleteFields);
    if (overlap.isNotEmpty) {
      throw ArgumentError.value(
        overlap,
        'deleteFields',
        'A field cannot be updated and deleted in the same request.',
      );
    }
    final fieldPaths = <String>{...fields.keys, ...deleteFields}.toList()
      ..sort();
    if (fieldPaths.isEmpty) return;
    try {
      await _dio.patch<dynamic>(
        '$_documentsBase/${_encodedPath(path)}',
        queryParameters: <String, dynamic>{
          'updateMask.fieldPaths': fieldPaths,
          if (requireExisting) 'currentDocument.exists': true,
        },
        data: <String, dynamic>{
          'fields': FirestoreValueCodec.encodeFields(
            _nestedFieldsForPaths(fields),
          ),
        },
        options: _options(idToken),
      );
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  /// Firestore REST expects a nested field map even when updateMask uses a
  /// dotted path. Encoding `settings.hide_ecchi_anime` as a literal field
  /// name would update the wrong key (or fail validation).
  Map<String, dynamic> _nestedFieldsForPaths(Map<String, dynamic> fields) {
    final nested = <String, dynamic>{};
    for (final entry in fields.entries) {
      final parts = entry.key
          .split('.')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList(growable: false);
      if (parts.isEmpty) {
        throw ArgumentError.value(entry.key, 'fields', 'Field path is empty.');
      }
      Map<String, dynamic> cursor = nested;
      for (var index = 0; index < parts.length - 1; index++) {
        final part = parts[index];
        final child = cursor.putIfAbsent(part, () => <String, dynamic>{});
        if (child is! Map<String, dynamic>) {
          throw ArgumentError.value(
            entry.key,
            'fields',
            'Field path conflicts with an existing value.',
          );
        }
        cursor = child;
      }
      final leaf = parts.last;
      if (cursor.containsKey(leaf) && parts.length > 1) {
        throw ArgumentError.value(
          entry.key,
          'fields',
          'A field path cannot be written more than once.',
        );
      }
      cursor[leaf] = entry.value;
    }
    return nested;
  }

  /// Writes ordinary fields and lets Firestore assign authoritative server
  /// timestamps in the same atomic commit. AnimeWitcher relies on
  /// FieldValue.serverTimestamp() for ordering lists and resolving progress
  /// conflicts, so client clock values must not be used for those fields.
  Future<void> setDocumentWithServerTimestamps(
    String path,
    Map<String, dynamic> fields,
    String idToken, {
    required Set<String> serverTimestampFields,
    bool merge = true,
  }) async {

    if (serverTimestampFields.isEmpty) {
      await setDocument(path, fields, idToken, merge: merge);
      return;
    }

    final ordinaryFields = Map<String, dynamic>.from(fields)
      ..removeWhere((key, _) => serverTimestampFields.contains(key));
    if (ordinaryFields.isEmpty && merge) {
      throw ArgumentError.value(
        fields,
        'fields',
        'Transform-only writes must replace the target document.',
      );
    }

    final write = <String, dynamic>{
      'update': <String, dynamic>{
        'name': _documentResource(path),
        'fields': FirestoreValueCodec.encodeFields(ordinaryFields),
      },
      if (merge)
        'updateMask': <String, dynamic>{
          'fieldPaths': ordinaryFields.keys.toList(growable: false),
        },
      'updateTransforms': serverTimestampFields
          .map<Map<String, dynamic>>(
            (field) => <String, dynamic>{
              'fieldPath': field,
              'setToServerValue': 'REQUEST_TIME',
            },
          )
          .toList(growable: false),
    };
    try {
      await _dio.post<dynamic>(
        '$_databaseBase/documents:commit',
        data: <String, dynamic>{
          'writes': <Map<String, dynamic>>[write],
        },
        options: _options(idToken),
      );
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  Future<FirestoreDocument> addDocument(
    String collectionPath,
    Map<String, dynamic> fields,
    String idToken,
  ) async {

    try {
      final response = await _dio.post<dynamic>(
        '$_documentsBase/${_encodedPath(collectionPath)}',
        data: <String, dynamic>{
          'fields': FirestoreValueCodec.encodeFields(fields),
        },
        options: _options(idToken),
      );
      final document = _decodeDocument(response.data);
      if (document == null) {
        throw const AnimeWitcherAccountException(
          'invalid-firestore-response',
          'The sync server returned an invalid document.',
        );
      }
      return document;
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  /// Creates a document with the same atomic server-timestamp behavior as
  /// Firebase's FieldValue.serverTimestamp(). Firestore SDKs generate random
  /// document IDs on the client, so doing that here still matches add().
  Future<FirestoreDocument> createDocumentWithServerTimestamps(
    String collectionPath,
    Map<String, dynamic> fields,
    String idToken, {
    required Set<String> serverTimestampFields,
    String? documentId,
  }) async {

    final id = documentId ?? _randomFirestoreDocumentId();
    final path = '${collectionPath.replaceFirst(RegExp(r'/+$'), '')}/$id';
    await setDocumentWithServerTimestamps(
      path,
      fields,
      idToken,
      serverTimestampFields: serverTimestampFields,
      merge: false,
    );
    final document = await getDocument(path, idToken);
    if (document == null) {
      throw const AnimeWitcherAccountException(
        'invalid-firestore-response',
        'The sync server did not return the created document.',
      );
    }
    return document;
  }

  /// Applies Firestore's atomic arrayUnion/arrayRemove equivalent while also
  /// ensuring the watched-document metadata exists. This matches the official
  /// AnimeWitcher client and prevents two devices updating different episodes
  /// at the same time from overwriting each other's arrays.
  Future<void> transformArrayField(
    String path, {
    required String idToken,
    required String field,
    required dynamic value,
    required bool append,
    Map<String, dynamic> baseFields = const <String, dynamic>{},
  }) async {

    final transform = <String, dynamic>{
      'fieldPath': field,
      if (append)
        'appendMissingElements': <String, dynamic>{
          'values': <Map<String, dynamic>>[FirestoreValueCodec.encode(value)],
        }
      else
        'removeAllFromArray': <String, dynamic>{
          'values': <Map<String, dynamic>>[FirestoreValueCodec.encode(value)],
        },
    };
    final Map<String, dynamic> write;
    if (baseFields.isEmpty) {
      // A transform-only write is the REST equivalent of
      // DocumentReference.update(field, FieldValue.arrayUnion/arrayRemove).
      // It changes only the requested array field and leaves every other
      // Firestore field untouched.
      write = <String, dynamic>{
        'transform': <String, dynamic>{
          'document': _documentResource(path),
          'fieldTransforms': <Map<String, dynamic>>[transform],
        },
      };
    } else {
      write = <String, dynamic>{
        'update': <String, dynamic>{
          'name': _documentResource(path),
          'fields': FirestoreValueCodec.encodeFields(baseFields),
        },
        'updateMask': <String, dynamic>{
          'fieldPaths': baseFields.keys.toList(growable: false),
        },
        'updateTransforms': <Map<String, dynamic>>[transform],
      };
    }
    try {
      await _dio.post<dynamic>(
        '$_databaseBase/documents:commit',
        data: <String, dynamic>{
          'writes': <Map<String, dynamic>>[write],
        },
        options: _options(idToken),
      );
    } on DioException catch (error) {
      throw _firestoreException(error);
    }
  }

  Future<void> deleteDocument(String path, String idToken) async {

    try {
      await _dio.delete<dynamic>(
        '$_documentsBase/${_encodedPath(path)}',
        options: _options(idToken),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return;
      throw _firestoreException(error);
    }
  }

  Options _publicOptions() {
    if (!AnimeWitcherAccountConfig.firestoreConfigured) {
      throw const AnimeWitcherAccountException(
        'not-configured',
        'AnimeWitcher Firestore is not configured.',
      );
    }
    return Options(
      contentType: Headers.jsonContentType,
      listFormat: ListFormat.multi,
    );
  }

  Options _options(String idToken) {
    if (!AnimeWitcherAccountConfig.firebaseConfigured) {
      throw const AnimeWitcherAccountException(
        'not-configured',
        'AnimeWitcher account services are not configured.',
      );
    }
    return Options(
      contentType: Headers.jsonContentType,
      headers: <String, String>{'Authorization': 'Bearer $idToken'},
      listFormat: ListFormat.multi,
    );
  }

  Future<FirestoreDocument> _hydrateContinueWatchingDocument(
    FirestoreDocument document,
    String idToken,
  ) async {
    final segments = document.path.split('/');
    if (segments.length < 4 ||
        segments[0] != 'users' ||
        segments[2] != 'continue_watching') {
      return document;
    }

    final fields = Map<String, dynamic>.from(document.fields);
    var position = _intValue(fields['position']);
    var duration = _intValue(fields['duration']);
    final progress = _intValue(fields['progress']).clamp(0, 100);
    final userId = segments[1];
    final animeId = _optionalString(fields['anime_id']) ?? document.id;
    final episodeId = _optionalString(fields['episode_id']);

    var stopTime = 0;
    if (episodeId != null) {
      final stopDocument = await getDocument(
        'users/$userId/episodes_watched/$animeId/stop_times/$episodeId',
        idToken,
      );
      stopTime = _intValue(stopDocument?.fields['stop_time']);
      if (position <= 0 && stopTime > 0) position = stopTime;
    }

    if (duration <= 0 && position > 0 && progress > 0) {
      final watchedForEstimate = stopTime > 0 ? stopTime + 2000 : position;
      if (progress >= 100) {
        duration = watchedForEstimate;
      } else {
        final minimumDuration = (watchedForEstimate * 100) / (progress + 1);
        final maximumDuration = (watchedForEstimate * 100) / progress;
        duration = ((minimumDuration + maximumDuration) / 2).round();
      }
    }

    if (duration <= 0) {
      duration = await _catalogDurationMillis(animeId, episodeId, idToken);
    }

    if (position <= 0 && duration > 0 && progress > 0) {
      final estimatedProgress = progress >= 100 ? 100.0 : progress + 0.5;
      position = ((duration * estimatedProgress) / 100)
          .round()
          .clamp(0, duration)
          .toInt();
    }

    if (position == _intValue(fields['position']) &&
        duration == _intValue(fields['duration'])) {
      return document;
    }
    fields['position'] = position;
    fields['duration'] = duration;
    return FirestoreDocument(
      id: document.id,
      path: document.path,
      fields: fields,
    );
  }

  Future<int> _catalogDurationMillis(
    String animeId,
    String? episodeId,
    String idToken,
  ) async {
    final cacheKey = '$animeId|${episodeId ?? ''}';
    final cached = _catalogDurationCache[cacheKey];
    if (cached != null) return cached;

    int minutes = 0;
    if (episodeId != null) {
      final episode = await getDocument(
        'anime_list/$animeId/episodes/$episodeId',
        idToken,
      );
      minutes = _durationMinutes(episode?.fields['duration']);
    }
    if (minutes <= 0) {
      final anime = await getDocument('anime_list/$animeId', idToken);
      minutes = _durationMinutes(anime?.fields['duration']);
    }

    final milliseconds = minutes > 0
        ? Duration(minutes: minutes).inMilliseconds
        : 0;
    _catalogDurationCache[cacheKey] = milliseconds;
    return milliseconds;
  }

  int _durationMinutes(dynamic raw) {
    if (raw is num) return raw.round();
    final match = RegExp(r'\d+(?:[.,]\d+)?').firstMatch(raw?.toString() ?? '');
    if (match == null) return 0;
    return double.tryParse(match.group(0)!.replaceAll(',', '.'))?.round() ?? 0;
  }

  List<FirestoreDocument> _decodeRunQueryDocuments(dynamic raw) {
    if (raw is! List) return const <FirestoreDocument>[];
    final output = <FirestoreDocument>[];
    for (final entry in raw) {
      final result = _map(entry);
      final document = _decodeDocument(result['document']);
      if (document != null) output.add(document);
    }
    return output;
  }

  FirestoreDocument? _decodeDocument(dynamic raw) {
    final source = _map(raw);
    final name = _optionalString(source['name']);
    if (name == null) return null;
    const marker = '/documents/';
    final markerIndex = name.indexOf(marker);
    final path = markerIndex < 0
        ? name
        : name.substring(markerIndex + marker.length);
    final segments = path.split('/');
    return FirestoreDocument(
      id: segments.isEmpty ? path : segments.last,
      path: path,
      fields: FirestoreValueCodec.decodeFields(_map(source['fields'])),
    );
  }
}

String _encodedPath(String path) => path
    .split('/')
    .where((segment) => segment.isNotEmpty)
    .map(Uri.encodeComponent)
    .join('/');

String _randomFirestoreDocumentId() {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random.secure();
  return List<String>.generate(
    20,
    (_) => alphabet[random.nextInt(alphabet.length)],
    growable: false,
  ).join();
}

Map<String, dynamic> _map(dynamic raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return <String, dynamic>{};
}

String? _optionalString(dynamic raw) {
  final value = raw?.toString().trim() ?? '';
  return value.isEmpty ? null : value;
}

int _intValue(dynamic raw) {
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

AnimeWitcherAccountException _firestoreException(DioException error) {
  final response = _map(error.response?.data);
  final nested = _map(response['error']);
  final status = (nested['status'] ?? '').toString().toUpperCase();
  final message = (nested['message'] ?? error.message ?? '').toString();
  if (error.response?.statusCode == 401 || status == 'UNAUTHENTICATED') {
    return const AnimeWitcherAccountException(
      'invalid-session',
      'The account session has expired. Please sign in again.',
    );
  }
  if (error.response?.statusCode == 403 || status == 'PERMISSION_DENIED') {
    return const AnimeWitcherAccountException(
      'permission-denied',
      'The AnimeWitcher server rejected this sync operation.',
    );
  }
  return AnimeWitcherAccountException(
    'sync-failed',
    message.isEmpty ? 'Could not synchronize account data.' : message,
  );
}

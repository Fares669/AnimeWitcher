import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

const _projectId = 'animewitcher-1c66d';
const _defaultAlgoliaAppId = '5UIU27G8CZ';
const _defaultAlgoliaSearchKey = 'ef06c5ee4a0d213c011694f18861805c';

const _mangaSortIndices = <String>[
  'manga_views_desc',
  'manga_name_asc',
  'manga_name_desc',
  'manga_year_asc',
  'manga_year_desc',
];

const _latestIndexCandidates = <String>['manga_recent'];

const _mangaLekMirrorHosts = <String>[
  'mangalik.net',
  'lekmanga.online',
  'like-manga.net',
  'lekmanga.site',
  'manga-leko.site',
];

final _dio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 8),
    sendTimeout: const Duration(seconds: 5),
    validateStatus: (status) => status != null && status >= 200 && status < 500,
    headers: const <String, String>{
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
          'Mobile/15E148 Safari/604.1',
    },
  ),
);

final class _AlgoliaCredentials {
  const _AlgoliaCredentials(this.label, this.appId, this.apiKey);

  final String label;
  final String appId;
  final String apiKey;

  bool get isUsable => appId.trim().isNotEmpty && apiKey.trim().isNotEmpty;
}

String _dioSummary(Object error) {
  if (error is! DioException) return error.runtimeType.toString();
  final status = error.response?.statusCode;
  return 'DioException(type=${error.type.name}, status=${status ?? 'none'})';
}

Future<Map<String, Object?>?> _algoliaFirst(
  String index,
  _AlgoliaCredentials credentials,
) async {
  final response = await _dio.post<Object?>(
    'https://${credentials.appId}-dsn.algolia.net/1/indexes/'
    '${Uri.encodeComponent(index)}/query',
    data: <String, Object?>{'query': '', 'hitsPerPage': 1, 'page': 0},
    options: Options(
      headers: <String, String>{
        'X-Algolia-Application-Id': credentials.appId,
        'X-Algolia-API-Key': credentials.apiKey,
        'X-Algolia-Agent': 'Algolia for Android (3.27.0); Android (13)',
        'content-type': 'application/json',
      },
    ),
  );
  if ((response.statusCode ?? 500) >= 300 || response.data is! Map) {
    return null;
  }
  final body = Map<String, Object?>.from(response.data! as Map);
  final hits = body['hits'];
  if (hits is! List || hits.isEmpty || hits.first is! Map) return null;
  return Map<String, Object?>.from(hits.first as Map);
}

String _documentsBase() =>
    'https://firestore.googleapis.com/v1/projects/$_projectId/'
    'databases/(default)/documents';

String _runQueryUrl([String parent = '']) {
  final base = _documentsBase();
  final clean = parent.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  return clean.isEmpty ? '$base:runQuery' : '$base/$clean:runQuery';
}

Future<Map<String, Object?>?> _firestoreDocument(String path) async {
  final response = await _dio.get<Object?>(
    '${_documentsBase()}/$path',
  );
  if ((response.statusCode ?? 500) >= 300 || response.data is! Map) {
    return null;
  }
  return Map<String, Object?>.from(response.data! as Map);
}

Future<Map<String, Object?>?> _firestoreFirst(
  String collectionId, {
  String parent = '',
}) async {
  final response = await _dio.post<Object?>(
    _runQueryUrl(parent),
    data: <String, Object?>{
      'structuredQuery': <String, Object?>{
        'from': <Object?>[
          <String, Object?>{'collectionId': collectionId},
        ],
        'limit': 1,
      },
    },
    options: Options(
      headers: const <String, String>{'content-type': 'application/json'},
    ),
  );
  if ((response.statusCode ?? 500) >= 300 || response.data is! List) {
    return null;
  }
  for (final row in response.data! as List) {
    if (row is! Map) continue;
    final document = row['document'];
    if (document is Map) return Map<String, Object?>.from(document);
  }
  return null;
}

Object? _decodeFirestoreValue(Object? raw) {
  if (raw is! Map) return null;
  final map = Map<String, Object?>.from(raw);
  if (map.containsKey('nullValue')) return null;
  if (map.containsKey('stringValue')) return map['stringValue']?.toString();
  if (map.containsKey('integerValue')) {
    return int.tryParse(map['integerValue'].toString());
  }
  if (map.containsKey('doubleValue')) return map['doubleValue'];
  if (map.containsKey('booleanValue')) return map['booleanValue'];
  if (map.containsKey('timestampValue')) return map['timestampValue']?.toString();
  if (map.containsKey('arrayValue')) {
    final array = map['arrayValue'];
    final values = array is Map ? array['values'] : null;
    if (values is! List) return const <Object?>[];
    return <Object?>[
      for (final value in values) _decodeFirestoreValue(value),
    ];
  }
  if (map.containsKey('mapValue')) {
    final nested = map['mapValue'];
    final fields = nested is Map ? nested['fields'] : null;
    return _decodeFirestoreFields(fields);
  }
  return null;
}

Map<String, Object?> _decodeFirestoreFields(Object? raw) {
  if (raw is! Map) return const <String, Object?>{};
  return <String, Object?>{
    for (final entry in raw.entries)
      entry.key.toString(): _decodeFirestoreValue(entry.value),
  };
}

String? _documentId(Map<String, Object?> document) {
  final name = document['name']?.toString();
  if (name == null || name.isEmpty) return null;
  final slash = name.lastIndexOf('/');
  return slash < 0 ? name : name.substring(slash + 1);
}

Map<String, Object?> _asMap(Object? raw) {
  if (raw is! Map) return const <String, Object?>{};
  return Map<String, Object?>.from(raw);
}

String _text(Object? raw) => raw?.toString().trim() ?? '';

List<_AlgoliaCredentials> _algoliaCredentials(
  Map<String, Object?> constants,
) {
  final search = _asMap(constants['search_settings']);
  final search2 = _asMap(constants['search_settings2']);

  _AlgoliaCredentials fromSettings(String label, Map<String, Object?> value) {
    final appId = _text(
      value['algolia_app_id2'] ??
          value['app_id_v3'] ??
          value['app_id'] ??
          value['application_id'],
    );
    final apiKey = _text(
      value['algolia_api_key2'] ??
          value['api_key'] ??
          value['search_api_key'],
    );
    return _AlgoliaCredentials(label, appId, apiKey);
  }

  final candidates = <_AlgoliaCredentials>[
    fromSettings('remote-primary', search),
    fromSettings('remote-secondary', search2),
    const _AlgoliaCredentials(
      'built-in-default',
      _defaultAlgoliaAppId,
      _defaultAlgoliaSearchKey,
    ),
  ];
  final seen = <String>{};
  return <_AlgoliaCredentials>[
    for (final candidate in candidates)
      if (candidate.isUsable &&
          seen.add('${candidate.appId}:${candidate.apiKey}'))
        candidate,
  ];
}

void _printSchema(String label, Map<String, Object?>? data) {
  if (data == null) {
    stdout.writeln('$label: unavailable');
    return;
  }
  final keys = data.keys.toList()..sort();
  stdout.writeln('$label: fields=[${keys.join(', ')}]');
}

Future<void> _probeMangaRecencyMetadata(
  List<_AlgoliaCredentials> credentials,
) async {
  for (final candidate in credentials) {
    try {
      final response = await _dio.post<Object?>(
        'https://${candidate.appId}-dsn.algolia.net/1/indexes/'
        'manga_views_desc/query',
        data: <String, Object?>{
          'query': '',
          'hitsPerPage': 3,
          'page': 0,
          'attributesToRetrieve': <String>[
            'objectID',
            'lastmodified',
            'date_created',
          ],
        },
        options: Options(
          headers: <String, String>{
            'X-Algolia-Application-Id': candidate.appId,
            'X-Algolia-API-Key': candidate.apiKey,
            'content-type': 'application/json',
          },
        ),
      );
      if ((response.statusCode ?? 500) >= 300 || response.data is! Map) {
        continue;
      }
      final body = Map<String, Object?>.from(response.data! as Map);
      stdout.writeln(
        'algolia:manga_views_desc metadata '
        'nbHits=${body['nbHits'] ?? 'unknown'}, '
        'nbPages=${body['nbPages'] ?? 'unknown'}',
      );
      final hits = body['hits'];
      if (hits is List) {
        for (final raw in hits.take(3)) {
          if (raw is! Map) continue;
          final hit = Map<String, Object?>.from(raw);
          stdout.writeln(
            'algolia:manga-recency-sample '
            'lastmodifiedType=${hit['lastmodified']?.runtimeType ?? 'null'} '
            'lastmodified=${_text(hit['lastmodified'])} '
            'dateCreatedType=${hit['date_created']?.runtimeType ?? 'null'} '
            'dateCreated=${_text(hit['date_created'])}',
          );
        }
      }
      return;
    } catch (error) {
      stdout.writeln(
        'algolia:manga-recency-metadata via ${candidate.label}: '
        '${_dioSummary(error)}',
      );
    }
  }
}

Future<void> _probeMangaFacets(
  List<_AlgoliaCredentials> credentials,
) async {
  for (final candidate in credentials) {
    try {
      final response = await _dio.post<Object?>(
        'https://${candidate.appId}-dsn.algolia.net/1/indexes/'
        'manga_views_desc/query',
        data: <String, Object?>{
          'query': '',
          'hitsPerPage': 0,
          'facets': <String>['type', 'statictes', 'details.year', 'tags'],
          'maxValuesPerFacet': 100,
        },
        options: Options(
          headers: <String, String>{
            'X-Algolia-Application-Id': candidate.appId,
            'X-Algolia-API-Key': candidate.apiKey,
            'content-type': 'application/json',
          },
        ),
      );
      if ((response.statusCode ?? 500) >= 300 || response.data is! Map) {
        continue;
      }
      final body = Map<String, Object?>.from(response.data! as Map);
      final facets = body['facets'];
      if (facets is! Map) {
        stdout.writeln('algolia:manga-facets: unavailable');
        return;
      }
      final map = Map<String, Object?>.from(facets);
      for (final key in <String>['type', 'statictes', 'details.year', 'tags']) {
        final values = map[key];
        if (values is Map) {
          final names = values.keys.map((value) => value.toString()).toList()
            ..sort();
          stdout.writeln(
            'algolia:manga-facet:$key=[${names.take(30).join(',')}]',
          );
        } else {
          stdout.writeln('algolia:manga-facet:$key=unavailable');
        }
      }
      return;
    } catch (error) {
      stdout.writeln(
        'algolia:manga-facets via ${candidate.label}: '
        '${_dioSummary(error)}',
      );
    }
  }
}

Future<void> _probeRecentMangaWindow(
  List<_AlgoliaCredentials> credentials,
) async {
  final threshold = DateTime.now()
      .toUtc()
      .subtract(const Duration(days: 7))
      .millisecondsSinceEpoch;
  for (final candidate in credentials) {
    try {
      final response = await _dio.post<Object?>(
        'https://${candidate.appId}-dsn.algolia.net/1/indexes/'
        'manga_views_desc/query',
        data: <String, Object?>{
          'query': '',
          'filters': 'lastmodified > $threshold',
          'hitsPerPage': 100,
          'page': 0,
          'attributesToRetrieve': <String>[
            'objectID',
            'lastmodified',
            'mangalek_page_url',
            'name',
          ],
        },
        options: Options(
          headers: <String, String>{
            'X-Algolia-Application-Id': candidate.appId,
            'X-Algolia-API-Key': candidate.apiKey,
            'content-type': 'application/json',
          },
        ),
      );
      if ((response.statusCode ?? 500) >= 300 || response.data is! Map) {
        continue;
      }
      final body = Map<String, Object?>.from(response.data! as Map);
      final hits = body['hits'];
      stdout.writeln(
        'algolia:manga-recent-window '
        'threshold=$threshold nbHits=${body['nbHits'] ?? 'unknown'} '
        'returned=${hits is List ? hits.length : 0}',
      );
      if (hits is List && hits.isNotEmpty) {
        final timestamps = <int>[
          for (final raw in hits)
            if (raw is Map)
              int.tryParse(
                    _text(Map<String, Object?>.from(raw)['lastmodified']),
                  ) ??
                  0,
        ]..sort((a, b) => b.compareTo(a));
        stdout.writeln(
          'algolia:manga-recent-window newest='
          '${timestamps.isEmpty ? 0 : timestamps.first}',
        );
      }
      return;
    } catch (error) {
      stdout.writeln(
        'algolia:manga-recent-window via ${candidate.label}: '
        '${_dioSummary(error)}',
      );
    }
  }
}

Future<void> _probeMangaIndexNames(
  Map<String, Object?> constants,
) async {
  final search = _asMap(constants['search_settings']);
  final search2 = _asMap(constants['search_settings2']);
  final candidates = <_AlgoliaCredentials>[];

  void add(String label, Map<String, Object?> value) {
    final appId = _text(
      value['algolia_app_id2'] ??
          value['app_id_v3'] ??
          value['app_id'] ??
          value['application_id'],
    );
    final browseKey = _text(value['browse_api_key'] ?? value['browseApiKey']);
    if (appId.isNotEmpty && browseKey.isNotEmpty) {
      candidates.add(_AlgoliaCredentials(label, appId, browseKey));
    }
  }

  add('remote-primary-browse', search);
  add('remote-secondary-browse', search2);

  for (final candidate in candidates) {
    try {
      final response = await _dio.get<Object?>(
        'https://${candidate.appId}-dsn.algolia.net/1/indexes',
        queryParameters: const <String, Object?>{'itemsPerPage': 100},
        options: Options(
          headers: <String, String>{
            'X-Algolia-Application-Id': candidate.appId,
            'X-Algolia-API-Key': candidate.apiKey,
          },
        ),
      );
      if ((response.statusCode ?? 500) >= 300 || response.data is! Map) {
        continue;
      }
      final body = Map<String, Object?>.from(response.data! as Map);
      final items = body['items'];
      if (items is! List) continue;
      final names = <String>[
        for (final raw in items)
          if (raw is Map)
            _text(Map<String, Object?>.from(raw)['name']),
      ].where((name) => name.toLowerCase().contains('manga')).toList()
        ..sort();
      stdout.writeln(
        'algolia:manga-index-names via ${candidate.label}='
        '${names.join(',')}',
      );
      if (names.isNotEmpty) return;
    } catch (error) {
      stdout.writeln(
        'algolia:index-list via ${candidate.label}: ${_dioSummary(error)}',
      );
    }
  }
}

Future<_AlgoliaCredentials?> _probeAlgoliaIndex(
  String index,
  List<_AlgoliaCredentials> credentials,
) async {
  for (final candidate in credentials) {
    try {
      final hit = await _algoliaFirst(index, candidate);
      if (hit != null) {
        _printSchema('algolia:$index via ${candidate.label}', hit);
        return candidate;
      }
      stdout.writeln(
        'algolia:$index via ${candidate.label}: empty/unavailable',
      );
    } catch (error) {
      stdout.writeln(
        'algolia:$index via ${candidate.label}: ${_dioSummary(error)}',
      );
    }
  }
  return null;
}

Future<bool> _probeMangaLek(String rawUrl) async {
  final original = Uri.tryParse(rawUrl.trim());
  if (original == null || !original.hasScheme || original.host.isEmpty) {
    stdout.writeln('mangalek: invalid catalog URL');
    return false;
  }

  final hosts = <String>[
    original.host,
    for (final host in _mangaLekMirrorHosts)
      if (host != original.host) host,
  ];

  for (final host in hosts) {
    final uri = original.replace(host: host, scheme: 'https');
    stdout.writeln(
      'mangalek: trying host=${uri.host}, '
      'pathSegments=${uri.pathSegments.length}',
    );
    try {
      final response = await _dio.get<String>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, String>{'Referer': 'https://${uri.host}/'},
        ),
      );
      final status = response.statusCode ?? 0;
      final html = response.data ?? '';
      final chapterMarkers = RegExp(
        'wp-manga-chapter',
        caseSensitive: false,
      ).allMatches(html).length;
      stdout.writeln(
        'mangalek:${uri.host}: status=$status, '
        'htmlBytes=${utf8.encode(html).length}, '
        'chapterMarkers=$chapterMarkers',
      );
      if (status < 200 || status >= 300 || html.isEmpty) continue;

      final chapterMatch = RegExp(
        r'''<li[^>]*class=["'][^"']*wp-manga-chapter[^"']*["'][^>]*>[\s\S]*?<a[^>]*href=["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(html);
      final chapterUrl = chapterMatch?.group(1)?.trim();
      if (chapterUrl == null || chapterUrl.isEmpty) {
        continue;
      }

      final chapterUri = uri.resolve(chapterUrl);
      final chapterResponse = await _dio.get<String>(
        chapterUri.toString(),
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, String>{'Referer': uri.toString()},
        ),
      );
      final chapterHtml = chapterResponse.data ?? '';
      final imageMatches = RegExp(
        r'''<img[^>]+(?:data-src|src)=["']([^"']+)["']''',
        caseSensitive: false,
      ).allMatches(chapterHtml);
      final readingMarkers = RegExp(
        'reading-content',
        caseSensitive: false,
      ).allMatches(chapterHtml).length;
      stdout.writeln(
        'mangalek:${uri.host}: chapterStatus='
        '${chapterResponse.statusCode ?? 0}, '
        'pageImageCandidates=${imageMatches.length}, '
        'readingContentMarkers=$readingMarkers',
      );
      if ((chapterResponse.statusCode ?? 0) >= 200 &&
          (chapterResponse.statusCode ?? 0) < 300 &&
          imageMatches.isNotEmpty) {
        return true;
      }
    } catch (error) {
      stdout.writeln('mangalek:${uri.host}: ${_dioSummary(error)}');
    }
  }

  return false;
}

Future<void> main() async {
  var failures = 0;

  stdout.writeln('AnimeWitcher Manga backend probe (read-only)');

  Map<String, Object?> constants = const <String, Object?>{};
  try {
    final document = await _firestoreDocument('Settings/constants');
    constants = _decodeFirestoreFields(document?['fields']);
    _printSchema('firestore:Settings/constants', constants);
  } catch (error) {
    stdout.writeln(
      'firestore:Settings/constants: ${_dioSummary(error)}',
    );
  }

  final searchSettings = _asMap(constants['search_settings']);
  final searchSettings2 = _asMap(constants['search_settings2']);
  for (final entry in <MapEntry<String, Object?>>[
    ...searchSettings.entries,
    ...searchSettings2.entries,
  ]) {
    final key = entry.key.toLowerCase();
    if ((key.contains('manga') || key.contains('index')) &&
        !key.contains('key') &&
        !key.contains('secret')) {
      final value = _text(entry.value);
      if (value.isNotEmpty) {
        stdout.writeln('settings:${entry.key}=$value');
      }
    }
  }

  final credentials = _algoliaCredentials(constants);
  stdout.writeln(
    'algolia: credentialProfiles=${credentials.map((e) => e.label).join(',')}',
  );
  await _probeMangaIndexNames(constants);
  await _probeMangaRecencyMetadata(credentials);
  await _probeRecentMangaWindow(credentials);
  await _probeMangaFacets(credentials);

  final supportedSortIndices = <String>[];
  for (final index in _mangaSortIndices) {
    if (await _probeAlgoliaIndex(index, credentials) != null) {
      supportedSortIndices.add(index);
    }
  }
  if (supportedSortIndices.isEmpty) failures++;
  stdout.writeln(
    'algolia:manga-supported-sort-indices='
    '${supportedSortIndices.join(',')}',
  );

  final supportedLatestIndices = <String>[];
  for (final index in _latestIndexCandidates) {
    if (await _probeAlgoliaIndex(index, credentials) != null) {
      supportedLatestIndices.add(index);
    }
  }
  stdout.writeln(
    'algolia:manga-supported-latest-indices='
    '${supportedLatestIndices.join(',')}',
  );

  try {
    final recentDocument = await _firestoreFirst('manga_recent');
    if (recentDocument == null) {
      stdout.writeln('firestore:manga_recent: unavailable');
    } else {
      _printSchema(
        'firestore:manga_recent',
        _decodeFirestoreFields(recentDocument['fields']),
      );
    }
  } catch (error) {
    stdout.writeln('firestore:manga_recent: ${_dioSummary(error)}');
  }

  Map<String, Object?>? mangaDocument;
  Map<String, Object?> mangaFields = const <String, Object?>{};
  try {
    mangaDocument = await _firestoreFirst('manga_list');
    if (mangaDocument == null) {
      failures++;
      stdout.writeln('firestore:manga_list: unavailable');
    } else {
      mangaFields = _decodeFirestoreFields(mangaDocument['fields']);
      _printSchema('firestore:manga_list', mangaFields);
    }
  } catch (error) {
    failures++;
    stdout.writeln('firestore:manga_list: ${_dioSummary(error)}');
  }

  final mangaId = mangaDocument == null ? null : _documentId(mangaDocument);
  var chaptersDiscovered = false;
  if (mangaId != null) {
    try {
      final chapterDocument = await _firestoreFirst(
        'chapters',
        parent: 'manga_list/$mangaId',
      );
      if (chapterDocument != null) {
        chaptersDiscovered = true;
        _printSchema(
          'firestore:chapters',
          _decodeFirestoreFields(chapterDocument['fields']),
        );
      } else {
        stdout.writeln('firestore:chapters: unavailable');
      }
    } catch (error) {
      stdout.writeln('firestore:chapters: ${_dioSummary(error)}');
    }
  }

  if (!chaptersDiscovered) {
    final mangaLekUrl = _text(
      mangaFields['mangalek_page_url'] ?? mangaFields['manga_page_url'],
    );
    if (mangaLekUrl.isEmpty || !await _probeMangaLek(mangaLekUrl)) {
      failures++;
    }
  }

  stdout.writeln(
    jsonEncode(<String, Object?>{
      'status': failures == 0 ? 'ok' : 'incomplete',
      'failedRequiredChecks': failures,
    }),
  );
  exitCode = failures == 0 ? 0 : 2;
}

import 'dart:convert';

import 'package:animewitcher/core/account/anime3rb_account_service.dart';
import 'package:animewitcher/core/account/anime3rb_comment_models.dart';
import 'package:animewitcher/core/account/anime3rb_comments_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/anime3rb_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime3rb_transport.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/features/settings/presentation/widgets/anime3rb_auth_webview_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

class _MemorySecureStorage extends SecureTokenStorage {
  _MemorySecureStorage() : super(MemoryStorageService());

  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

class _RecordingTransport implements Anime3rbTransport {
  final List<({String method, Uri uri, Map<String, String> headers, Object? body})>
  calls = [];
  late Future<Anime3rbHttpResponse> Function(
    String method,
    Uri uri,
    Object? body,
    Map<String, String> headers,
  )
  handler;

  @override
  Future<Anime3rbHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  }) {
    calls.add((method: 'GET', uri: uri, headers: headers, body: null));
    return handler('GET', uri, null, headers);
  }

  @override
  Future<Anime3rbHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  }) {
    calls.add((method: 'POST', uri: uri, headers: headers, body: body));
    return handler('POST', uri, body, headers);
  }

  @override
  Future<Anime3rbHttpResponse> put(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'put',
  }) {
    calls.add((method: 'PUT', uri: uri, headers: headers, body: body));
    return handler('PUT', uri, body, headers);
  }

  @override
  Future<Anime3rbHttpResponse> delete(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'delete',
  }) {
    calls.add((method: 'DELETE', uri: uri, headers: headers, body: body));
    return handler('DELETE', uri, body, headers);
  }

  @override
  Future<String> fetchHtml(
    Uri uri, {
    Map<String, String> headers = const {},
    CancelToken? cancelToken,
    String operation = 'catalog',
  }) async => (await get(uri, headers: headers)).body;

  @override
  void close({bool force = false}) {}
}

String _htmlAttr(String raw) => const HtmlEscape().convert(raw);

void main() {
  test('parseProfileFromHtml extracts Livewire profile, IPTV, notifications and watching-list', () {
    final profileSnap = jsonEncode({
      'data': {
        'profile_photo_url': '/storage/avatars/user.png',
        'state': [
          {
            'id': 123007,
            'name': 'Fares 69',
            'slug': 'fares-69',
            'email': 'user@example.com',
            'data': [
              {
                'watching-list': [
                  {
                    'one-piece': [
                      {
                        'video': 1180,
                        'time': 25.9,
                        'progress': 42.5,
                        'updated_at': 1700000000000,
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      },
      'memo': {'name': 'profile.update-profile-information-form'},
    });
    final iptvSnap = jsonEncode({
      'data': {'xtream_username': 'u1', 'xtream_quality': '1080p'},
      'memo': {'name': 'profile.iptv-credentials'},
    });
    final html = '''
      <html>
        <head><meta name="csrf-token" content="csrf123"></head>
        <body>
          <form action="https://anime3rb.com/logout" method="POST"></form>
          <div wire:name="notification.notifications-icon"><span class="sr-only">3 إشعار غير مقروء</span></div>
          <div wire:name="profile.update-profile-information-form" wire:snapshot="${_htmlAttr(profileSnap)}"></div>
          <div wire:name="profile.iptv-credentials" wire:snapshot="${_htmlAttr(iptvSnap)}"></div>
        </body>
      </html>
    ''';

    final profile = parseProfileFromHtml(
      html,
      baseUri: Uri.parse('https://anime3rb.com/user/profile'),
    );
    expect(profile, isNotNull);
    expect(profile!.accountId, '123007');
    expect(profile.userSlug, 'fares-69');
    expect(profile.displayName, 'Fares 69');
    expect(profile.email, 'user@example.com');
    expect(profile.avatarUrl, 'https://anime3rb.com/storage/avatars/user.png');
    expect(profile.xtreamUsername, 'u1');
    expect(profile.xtreamQuality, '1080p');
    expect(profile.unreadNotifications, 3);
    expect(profile.watchingProgress['one-piece']?.episodeNumber, 1180);
    expect(profile.watchingProgress['one-piece']?.timeSeconds, 25.9);

    final unauthenticated = parseProfileFromHtml(
      '<html><body><form action="/login"></form></body></html>',
      baseUri: Uri.parse('https://anime3rb.com/login'),
    );
    expect(unauthenticated, isNull);
  });

  test('Anime3rbAccountService persists session, updates watching-list cookie, and restores', () async {
    final transport = _RecordingTransport();
    final storage = _MemorySecureStorage();
    final snap = jsonEncode({
      'data': {
        'state': [
          {
            'id': 77,
            'name': 'Tester',
            'slug': 'tester-slug',
            'email': 'tester@example.com',
          },
        ],
      },
      'memo': {'name': 'profile.update-profile-information-form'},
    });
    transport.handler = (method, uri, body, headers) async {
      if (uri.path == '/user/profile' && method == 'GET') {
        if ((headers['Cookie'] ?? '').contains('anime3rb_session=ok')) {
          return Anime3rbHttpResponse(
            statusCode: 200,
            finalUri: uri,
            body: '''
              <meta name="csrf-token" content="tok1">
              <form action="/logout"></form>
              <div wire:name="profile.update-profile-information-form" wire:snapshot="${_htmlAttr(snap)}"></div>
            ''',
          );
        }
        return Anime3rbHttpResponse(
          statusCode: 200,
          finalUri: Uri.parse('https://anime3rb.com/login'),
          body: '<form action="/login"></form>',
        );
      }
      return const Anime3rbHttpResponse(statusCode: 200, body: '{}');
    };

    final service = Anime3rbAccountService(
      tokenStorage: storage,
      backend: HttpAnime3rbAccountBackend(transport),
    );
    expect(await service.tryCompleteBrowserAuth(sessionCookie: 'bad=1'), isNull);
    expect(service.isSignedIn, isFalse);

    final result = await service.completeBrowserAuth(
      sessionCookie: 'anime3rb_session=ok; XSRF-TOKEN=abc',
      csrfToken: 'tok1',
    );
    expect(result.profile.userSlug, 'tester-slug');
    expect(service.isSignedIn, isTrue);

    await service.recordEpisodeProgress(
      animeUrl: 'https://anime3rb.com/titles/one-piece',
      episodeNumber: 1180,
      timeSeconds: 145.5,
      progressPercent: 18.0,
    );
    final cookieHeader = service.requestCookieHeader();
    expect(cookieHeader, contains('anime3rb_session=ok'));
    expect(cookieHeader, contains('watching-list='));
    final decodedWatching = jsonDecode(
      Uri.decodeComponent(
        RegExp(r'watching-list=([^;]+)').firstMatch(cookieHeader)!.group(1)!,
      ),
    ) as Map<String, dynamic>;
    expect((decodedWatching['one-piece'] as Map)['video'], 1180);

    final restored = Anime3rbAccountService(
      tokenStorage: storage,
      backend: HttpAnime3rbAccountBackend(transport),
    );
    await restored.restoreSession();
    expect(restored.isSignedIn, isTrue);
    expect(restored.profile?.watchingProgress['one-piece']?.episodeNumber, 1180);

    await restored.signOut();
    expect(restored.isSignedIn, isFalse);
  });

  test('parseReportFormFromSnapshot & parseNotificationsFromHtml parse structures', () {
    final snap = jsonEncode({
      'data': {
        'reportingBlocked': false,
        'issuesTree': [
          [
            [
              {
                'id': 1,
                'label': 'مشكلة في الفيديو',
                'requires_additional_details': false,
                'children': [
                  [
                    [
                      {
                        'id': 2,
                        'label': 'الفيديو لا يعمل',
                        'note': 'جرب فيديو آخر أولًا.',
                        'requires_additional_details': false,
                        'children': [[], {'s': 'arr'}],
                      },
                      {'s': 'arr'},
                    ],
                  ],
                  {'s': 'arr'},
                ],
              },
              {'s': 'arr'},
            ],
          ],
          {'s': 'arr'},
        ],
      },
    });
    final parsed = parseReportFormFromSnapshot(snap);
    expect(parsed.issues, hasLength(1));
    expect(parsed.issues.first.children.single.id, 2);
    expect(parsed.issues.first.children.single.note, 'جرب فيديو آخر أولًا.');

    final notifications = parseNotificationsFromHtml('''
      <div>
        <a href="/episode/one-piece/1180" class="unread bg-primary-50">تم رفع الحلقة 1180</a>
        <a href="#">لا إشعارات</a>
      </div>
    ''');
    expect(notifications, hasLength(1));
    expect(notifications.single.title, 'تم رفع الحلقة 1180');
    expect(notifications.single.unread, isTrue);
    expect(
      notifications.single.url,
      'https://anime3rb.com/episode/one-piece/1180',
    );
  });

  test('Anime3rbCommentsService handles bootstrap, SSO exchange, read, create, reply, edit, delete & vote', () async {
    final transport = _RecordingTransport();
    final storage = _MemorySecureStorage();
    final comntoCalls = <({String method, String path, Object? body, String? auth})>[];

    final profileSnap = jsonEncode({
      'data': {
        'state': [
          {'id': 501, 'name': 'Commenter', 'slug': 'commenter'},
        ],
      },
    });

    final titleEffects = jsonEncode({
      'scripts': {
        's0': "<script>window.comnto({el:'#comments',site:'anime3rb',topic:'title-4',sso:'signed.sso.token'});</script>",
      },
    });
    final comntoSnapshot = jsonEncode({
      'data': {'identifier': 'title-4'},
    });

    var currentBodyHtml = '<p>أول تعليق</p>';
    var currentVote = 0;

    transport.handler = (method, uri, body, headers) async {
      if (uri.host == 'anime3rb.com') {
        if (uri.path == '/user/profile') {
          return Anime3rbHttpResponse(
            statusCode: 200,
            finalUri: uri,
            body: '''
              <form action="/logout"></form>
              <div wire:name="profile.update-profile-information-form" wire:snapshot="${_htmlAttr(profileSnap)}"></div>
            ''',
          );
        }
        return Anime3rbHttpResponse(
          statusCode: 200,
          finalUri: uri,
          body: '''
            <html><head><title>One Piece</title></head><body>
              <div wire:name="comnto" wire:snapshot="${_htmlAttr(comntoSnapshot)}" wire:effects="${_htmlAttr(titleEffects)}"></div>
            </body></html>
          ''',
        );
      }

      comntoCalls.add((
        method: method,
        path: uri.path,
        body: body,
        auth: headers['Authorization'],
      ));

      if (uri.path == '/v1/anime3rb/sso' && method == 'POST') {
        return Anime3rbHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'token': 'jwt-comnto-1',
            'refresh_token': 'ref-1',
            'data': {'uuid': 'viewer-uuid-1'},
          }),
        );
      }

      if (uri.path == '/v1/anime3rb/topics/title-4/comments' && method == 'GET') {
        return Anime3rbHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'data': [
              {
                'uuid': 'c-1',
                'body': currentBodyHtml,
                'user': {'uuid': 'viewer-uuid-1', 'name': 'Commenter'},
                'replies_count': 1,
                'votes': {
                  'upvotes_count': currentVote == 1 ? 2 : 1,
                  'downvotes_count': 0,
                  'user_vote': currentVote == 0 ? null : currentVote,
                },
                'created_at': '2026-11-22T07:00:00Z',
              },
            ],
            'meta': {'next_cursor': 'cur-2', 'has_more': true, 'total': 48},
            'topic': {'is_closed': false, 'comments_count': 48},
          }),
        );
      }

      if (uri.path == '/v1/anime3rb/topics/title-4/comments' && method == 'POST') {
        final payload = jsonDecode(body as String) as Map<String, dynamic>;
        currentBodyHtml = payload['body'].toString();
        return Anime3rbHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'data': {
              'uuid': payload['parent_uuid'] != null ? 'r-1' : 'c-2',
              'body': currentBodyHtml,
              'parent': payload['parent_uuid'],
              'user': {'uuid': 'viewer-uuid-1', 'name': 'Commenter'},
              'replies_count': 0,
              'votes': {'upvotes_count': 0, 'downvotes_count': 0},
              'created_at': '2026-11-22T08:00:00Z',
            },
          }),
        );
      }

      if (uri.path == '/v1/anime3rb/comments/c-1' && method == 'PUT') {
        final payload = jsonDecode(body as String) as Map<String, dynamic>;
        currentBodyHtml = payload['body'].toString();
        return Anime3rbHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'data': {
              'uuid': 'c-1',
              'body': currentBodyHtml,
              'user': {'uuid': 'viewer-uuid-1', 'name': 'Commenter'},
              'is_edited': true,
              'votes': {'upvotes_count': 1, 'downvotes_count': 0},
            },
          }),
        );
      }

      if (uri.path == '/v1/anime3rb/comments/c-1/vote' && method == 'POST') {
        currentVote = 1;
        return Anime3rbHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'data': {
              'uuid': 'c-1',
              'body': currentBodyHtml,
              'user': {'uuid': 'viewer-uuid-1', 'name': 'Commenter'},
              'votes': {'upvotes_count': 2, 'downvotes_count': 0, 'user_vote': 1},
            },
          }),
        );
      }

      if (uri.path == '/v1/anime3rb/comments/c-1/vote' && method == 'DELETE') {
        currentVote = 0;
        return Anime3rbHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'data': {
              'uuid': 'c-1',
              'body': currentBodyHtml,
              'user': {'uuid': 'viewer-uuid-1', 'name': 'Commenter'},
              'votes': {'upvotes_count': 1, 'downvotes_count': 0, 'user_vote': null},
            },
          }),
        );
      }

      if (uri.path == '/v1/anime3rb/comments/c-1' && method == 'DELETE') {
        return const Anime3rbHttpResponse(statusCode: 200, body: '{"success":true}');
      }

      if (uri.path == '/v1/anime3rb/comments/c-1/replies' && method == 'GET') {
        return Anime3rbHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'success': true,
            'data': [
              {
                'uuid': 'r-0',
                'parent': 'c-1',
                'body': '<p>رد محفوظ</p>',
                'user': {'uuid': 'other-1', 'name': 'Other'},
                'votes': {'upvotes_count': 0, 'downvotes_count': 0},
              },
            ],
            'meta': {'has_more': false},
          }),
        );
      }

      return const Anime3rbHttpResponse(statusCode: 404, body: '{}');
    };

    final accountService = Anime3rbAccountService(
      tokenStorage: storage,
      backend: HttpAnime3rbAccountBackend(transport),
    );
    await accountService.completeBrowserAuth(sessionCookie: 'anime3rb_session=ok');

    final commentsService = Anime3rbCommentsService(
      accountService: accountService,
      backend: HttpAnime3rbCommentsBackend(transport),
    );

    final target = Anime3rbCommentTarget.fromAnime(
      MultimediaItem(
        title: 'One Piece',
        url: 'https://anime3rb.com/titles/one-piece',
        posterUrl: '',
        provider: Anime3rbProvider.id,
      ),
    )!;

    final page = await commentsService.loadComments(target);
    expect(page.items.single.bodyText, 'أول تعليق');
    expect(page.totalCount, 48);
    expect(page.hasMore, isTrue);
    expect(accountService.session?.comntoToken, 'jwt-comnto-1');

    final created = await commentsService.createComment(
      target,
      text: 'سطر 1\nسطر 2 <test>',
    );
    expect(created.uuid, 'c-2');
    expect(created.bodyHtml, '<p>سطر 1<br>سطر 2 &lt;test&gt;</p>');

    final reply = await commentsService.createComment(
      target,
      text: 'رد جديد',
      parentUuid: 'c-1',
    );
    expect(reply.parentUuid, 'c-1');

    final repliesPage = await commentsService.loadReplies(target, 'c-1');
    expect(repliesPage.items.single.bodyText, 'رد محفوظ');

    final upvoted = await commentsService.toggleVote(target, page.items.single, 1);
    expect(upvoted.userVote, 1);
    expect(upvoted.upvotesCount, 2);

    final unvoted = await commentsService.toggleVote(target, upvoted, 1);
    expect(unvoted.userVote, isNull);

    final edited = await commentsService.editComment(
      target,
      commentUuid: 'c-1',
      text: 'معدّل',
    );
    expect(edited.isEdited, isTrue);
    expect(edited.bodyText, 'معدّل');

    await commentsService.deleteComment(target, commentUuid: 'c-1');
    expect(
      comntoCalls.where((c) => c.method == 'DELETE' && c.path.endsWith('/c-1')),
      isNotEmpty,
    );

    final epTarget = Anime3rbCommentTarget.fromEpisode(
      MultimediaItem(
        title: 'One Piece',
        url: 'https://anime3rb.com/titles/one-piece',
        posterUrl: '',
        provider: Anime3rbProvider.id,
      ),
      Episode(
        name: '1180',
        url: 'https://anime3rb.com/episode/one-piece/1180',
        episode: 1180,
      ),
    );
    expect(epTarget?.isEpisode, isTrue);
    expect(epTarget?.pageUrl, 'https://anime3rb.com/episode/one-piece/1180');
  });

  test('parseAnime3rbDocumentCookies decodes JSON and cookie headers', () {
    final parsed = parseAnime3rbDocumentCookies(
      '"watching-list=%7B%7D; XSRF-TOKEN=abc"',
    );
    expect(parsed['XSRF-TOKEN'], 'abc');
    expect(
      formatAnime3rbCookieHeader({'a': '1', 'b': '2'}),
      'a=1; b=2',
    );
  });
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html_parser;

import '../extensions/providers/anime3rb_provider.dart';
import '../extensions/providers/anime3rb_transport.dart';
import 'anime3rb_account_service.dart';
import 'anime3rb_comment_models.dart';
import 'anime3rb_livewire.dart';

class Anime3rbComntoBootstrap {
  const Anime3rbComntoBootstrap({
    required this.topic,
    this.ssoToken,
    this.pageTitle,
  });

  final String topic;
  final String? ssoToken;
  final String? pageTitle;
}

class Anime3rbCommentsException implements Exception {
  const Anime3rbCommentsException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

abstract interface class Anime3rbCommentsBackend {
  Future<Anime3rbComntoBootstrap> resolveBootstrap({
    required Uri pageUri,
    String? sessionCookie,
  });

  Future<({String token, String? refreshToken, String? viewerUuid})?>
  exchangeSso(String ssoToken);

  Future<Anime3rbCommentPage> loadComments({
    required String topic,
    required String pageUrl,
    required Anime3rbCommentSort sort,
    String? cursor,
    int limit = 20,
    String? bearerToken,
  });

  Future<Anime3rbCommentPage> loadReplies({
    required String commentUuid,
    required Anime3rbCommentSort sort,
    String? cursor,
    int limit = 20,
    String? bearerToken,
  });

  Future<Anime3rbComment> createComment({
    required String topic,
    required String pageUrl,
    required String pageTitle,
    required String bodyHtml,
    required String bearerToken,
    String? parentUuid,
  });

  Future<Anime3rbComment> editComment({
    required String commentUuid,
    required String bodyHtml,
    required String bearerToken,
  });

  Future<void> deleteComment({
    required String commentUuid,
    required String bearerToken,
  });

  Future<Anime3rbComment> voteComment({
    required String commentUuid,
    required int value,
    required String bearerToken,
  });

  Future<Anime3rbComment> deleteVote({
    required String commentUuid,
    required String bearerToken,
  });

  Future<void> reportComment({
    required String commentUuid,
    required String reason,
    String? details,
    required String bearerToken,
  });
}

class HttpAnime3rbCommentsBackend implements Anime3rbCommentsBackend {
  HttpAnime3rbCommentsBackend(this._transport, {Uri? comntoOrigin})
    : _comntoOrigin = comntoOrigin ?? Uri.https('embed.comnto.com');

  final Anime3rbTransport _transport;
  final Uri _comntoOrigin;

  static const String _siteSlug = 'anime3rb';
  static final String _parentOrigin = Anime3rbProvider.originUrl;

  Uri _api(String path, [Map<String, String>? query]) =>
      _comntoOrigin.replace(path: '/v1/$_siteSlug$path', queryParameters: query);

  Map<String, String> _comntoHeaders({String? bearerToken}) => <String, String>{
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'Origin': _comntoOrigin.origin,
    'Referer': '${_comntoOrigin.origin}/',
    if (bearerToken != null && bearerToken.trim().isNotEmpty)
      'Authorization': 'Bearer ${bearerToken.trim()}',
  };

  @override
  Future<Anime3rbComntoBootstrap> resolveBootstrap({
    required Uri pageUri,
    String? sessionCookie,
  }) async {
    final resp = await _transport.get(
      pageUri,
      headers: <String, String>{
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        if (sessionCookie != null && sessionCookie.trim().isNotEmpty)
          'Cookie': sessionCookie.trim(),
      },
      operation: 'comnto_bootstrap',
    );
    if (resp.isCloudflareChallenge) {
      throw Anime3rbBrowserRequiredException(
        'يتطلب تحميل التعليقات إكمال تحقق المتصفح على Anime3rb.',
        watchUrl: pageUri,
      );
    }
    if (!resp.isSuccess) {
      throw Anime3rbCommentsException(
        'تعذر فتح صفحة التعليقات (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final parsed = extractComntoBootstrapFromHtml(resp.body);
    if (parsed == null) {
      throw const Anime3rbCommentsException(
        'لم يتم العثور على قسم التعليقات في هذه الصفحة.',
      );
    }
    return parsed;
  }

  @override
  Future<({String token, String? refreshToken, String? viewerUuid})?>
  exchangeSso(String ssoToken) async {
    final resp = await _transport.post(
      _api('/sso', <String, String>{'parent': _parentOrigin}),
      body: jsonEncode(<String, Object?>{'sso': ssoToken}),
      headers: _comntoHeaders(),
      operation: 'comnto_sso',
    );
    if (!resp.isSuccess) return null;
    final decoded = _decodeJsonMap(resp.body);
    final token = decoded?['token']?.toString().trim() ?? '';
    if (token.isEmpty || decoded?['success'] != true) return null;
    final viewerMap = decoded?['data'] is Map
        ? Map<String, dynamic>.from(decoded!['data'] as Map)
        : const <String, dynamic>{};
    return (
      token: token,
      refreshToken: decoded?['refresh_token']?.toString().trim(),
      viewerUuid: viewerMap['uuid']?.toString().trim(),
    );
  }

  @override
  Future<Anime3rbCommentPage> loadComments({
    required String topic,
    required String pageUrl,
    required Anime3rbCommentSort sort,
    String? cursor,
    int limit = 20,
    String? bearerToken,
  }) async {
    final query = <String, String>{
      'limit': limit.toString(),
      'sort_by': sort.apiValue,
      'include': 'site-topic-counts-notifications',
      'page_url': pageUrl,
      'parent': _parentOrigin,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };
    final resp = await _transport.get(
      _api('/topics/$topic/comments', query),
      headers: _comntoHeaders(bearerToken: bearerToken),
      operation: 'comnto_list',
    );
    _throwIfFailed(resp, 'تعذر تحميل التعليقات.');
    final root = _decodeJsonMap(resp.body);
    if (root == null) {
      throw const Anime3rbCommentsException('استجابة التعليقات غير صالحة.');
    }
    return _parseCommentPage(topic: topic, root: root);
  }

  @override
  Future<Anime3rbCommentPage> loadReplies({
    required String commentUuid,
    required Anime3rbCommentSort sort,
    String? cursor,
    int limit = 20,
    String? bearerToken,
  }) async {
    final query = <String, String>{
      'limit': limit.toString(),
      'sort_by': sort.apiValue,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };
    final resp = await _transport.get(
      _api('/comments/$commentUuid/replies', query),
      headers: _comntoHeaders(bearerToken: bearerToken),
      operation: 'comnto_replies',
    );
    _throwIfFailed(resp, 'تعذر تحميل الردود.');
    final root = _decodeJsonMap(resp.body);
    if (root == null) {
      throw const Anime3rbCommentsException('استجابة الردود غير صالحة.');
    }
    return _parseCommentPage(topic: commentUuid, root: root);
  }

  @override
  Future<Anime3rbComment> createComment({
    required String topic,
    required String pageUrl,
    required String pageTitle,
    required String bodyHtml,
    required String bearerToken,
    String? parentUuid,
  }) async {
    final resp = await _transport.post(
      _api('/topics/$topic/comments'),
      body: jsonEncode(<String, Object?>{
        'body': bodyHtml,
        'page_url': pageUrl,
        'page_title': pageTitle,
        if (parentUuid != null && parentUuid.isNotEmpty)
          'parent_uuid': parentUuid,
      }),
      headers: _comntoHeaders(bearerToken: bearerToken),
      operation: 'comnto_create',
    );
    _throwIfFailed(resp, 'تعذر نشر التعليق.');
    final root = _decodeJsonMap(resp.body);
    final comment = Anime3rbComment.fromJson(root?['data']);
    if (comment == null) {
      throw const Anime3rbCommentsException('تم النشر ولكن تعذر قراءة التعليق.');
    }
    return comment;
  }

  @override
  Future<Anime3rbComment> editComment({
    required String commentUuid,
    required String bodyHtml,
    required String bearerToken,
  }) async {
    final uri = _api('/comments/$commentUuid');
    final resp = await _transport.put(
      uri,
      body: jsonEncode(<String, Object?>{'body': bodyHtml}),
      headers: _comntoHeaders(bearerToken: bearerToken),
      operation: 'comnto_edit',
    );
    _throwIfFailed(resp, 'تعذر تعديل التعليق.');
    final root = _decodeJsonMap(resp.body);
    final comment = Anime3rbComment.fromJson(root?['data']);
    if (comment == null) {
      throw const Anime3rbCommentsException('تعذر قراءة التعليق المعدل.');
    }
    return comment;
  }

  @override
  Future<void> deleteComment({
    required String commentUuid,
    required String bearerToken,
  }) async {
    final resp = await _transport.delete(
      _api('/comments/$commentUuid'),
      headers: _comntoHeaders(bearerToken: bearerToken),
      operation: 'comnto_delete',
    );
    _throwIfFailed(resp, 'تعذر حذف التعليق.');
  }

  @override
  Future<Anime3rbComment> voteComment({
    required String commentUuid,
    required int value,
    required String bearerToken,
  }) async {
    final resp = await _transport.post(
      _api('/comments/$commentUuid/vote'),
      body: jsonEncode(<String, Object?>{'value': value}),
      headers: _comntoHeaders(bearerToken: bearerToken),
      operation: 'comnto_vote',
    );
    _throwIfFailed(resp, 'تعذر تسجيل التفاعل.');
    final root = _decodeJsonMap(resp.body);
    final comment = Anime3rbComment.fromJson(root?['data']);
    if (comment == null) {
      throw const Anime3rbCommentsException('تعذر تحديث نتيجة التفاعل.');
    }
    return comment;
  }

  @override
  Future<Anime3rbComment> deleteVote({
    required String commentUuid,
    required String bearerToken,
  }) async {
    final resp = await _transport.delete(
      _api('/comments/$commentUuid/vote'),
      headers: _comntoHeaders(bearerToken: bearerToken),
      operation: 'comnto_unvote',
    );
    _throwIfFailed(resp, 'تعذر إلغاء التفاعل.');
    final root = _decodeJsonMap(resp.body);
    final comment = Anime3rbComment.fromJson(root?['data']);
    if (comment == null) {
      throw const Anime3rbCommentsException('تعذر تحديث نتيجة التفاعل.');
    }
    return comment;
  }

  @override
  Future<void> reportComment({
    required String commentUuid,
    required String reason,
    String? details,
    required String bearerToken,
  }) async {
    final resp = await _transport.post(
      _api('/comments/$commentUuid/report'),
      body: jsonEncode(<String, Object?>{
        'reason': reason,
        if (details != null && details.trim().isNotEmpty)
          'details': details.trim(),
      }),
      headers: _comntoHeaders(bearerToken: bearerToken),
      operation: 'comnto_report',
    );
    _throwIfFailed(resp, 'تعذر إرسال البلاغ.');
  }

  static Map<String, dynamic>? _decodeJsonMap(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static void _throwIfFailed(Anime3rbHttpResponse resp, String fallback) {
    if (resp.isSuccess) return;
    if (resp.statusCode == 401) {
      throw const Anime3rbAuthRequiredException(
        'انتهت جلسة التعليقات، يرجى تسجيل الدخول إلى Anime3rb.',
      );
    }
    final root = _decodeJsonMap(resp.body);
    final error = root?['error']?.toString().trim() ??
        root?['message']?.toString().trim();
    throw Anime3rbCommentsException(
      (error != null && error.isNotEmpty)
          ? error
          : '$fallback (HTTP ${resp.statusCode})',
      statusCode: resp.statusCode,
    );
  }

  static Anime3rbCommentPage _parseCommentPage({
    required String topic,
    required Map<String, dynamic> root,
  }) {
    final data = root['data'];
    final items = <Anime3rbComment>[];
    if (data is List) {
      for (final raw in data) {
        final comment = Anime3rbComment.fromJson(raw);
        if (comment != null) items.add(comment);
      }
    }
    final meta = root['meta'] is Map
        ? Map<String, dynamic>.from(root['meta'] as Map)
        : const <String, dynamic>{};
    final topicMap = root['topic'] is Map
        ? Map<String, dynamic>.from(root['topic'] as Map)
        : const <String, dynamic>{};
    final viewerMap = root['viewer'] is Map
        ? Map<String, dynamic>.from(root['viewer'] as Map)
        : const <String, dynamic>{};
    final nextCursor = meta['next_cursor']?.toString().trim();
    final rawTotal = meta['total'] ?? topicMap['comments_count'];
    final total = rawTotal is num
        ? rawTotal.toInt()
        : int.tryParse(rawTotal?.toString() ?? '');
    return Anime3rbCommentPage(
      topic: topic,
      items: items,
      totalCount: total,
      nextCursor: (nextCursor != null && nextCursor.isNotEmpty)
          ? nextCursor
          : null,
      hasMore: meta['has_more'] == true,
      isTopicClosed: topicMap['is_closed'] == true || topicMap['locked'] == true,
      viewerUuid: viewerMap['uuid']?.toString().trim(),
    );
  }
}

@visibleForTesting
Anime3rbComntoBootstrap? extractComntoBootstrapFromHtml(String html) {
  final doc = html_parser.parse(html);
  final comnto = Anime3rbLivewireClient.findComponent(doc, 'comnto');
  String? topic = comnto?.decodedSnapshot?['data'] is Map
      ? (comnto!.decodedSnapshot!['data'] as Map)['identifier']?.toString().trim()
      : null;
  String? sso;

  final effectsAttr = comnto?.element?.attributes['wire:effects'];
  if (effectsAttr != null && effectsAttr.isNotEmpty) {
    try {
      final effects = jsonDecode(effectsAttr);
      final scripts = effects is Map ? effects['scripts'] : null;
      if (scripts is Map) {
        for (final scriptHtml in scripts.values) {
          final text = scriptHtml.toString();
          topic ??= RegExp(
            r'''topic\s*:\s*['"]([^'"]+)['"]''',
          ).firstMatch(text)?.group(1);
          sso ??= RegExp(
            r'''sso\s*:\s*['"]([^'"]+)['"]''',
          ).firstMatch(text)?.group(1);
        }
      }
    } catch (_) {}
  }

  // Fallback: match window.comnto({ ... }) directly in page scripts or iframe URL.
  if (topic == null || topic.isEmpty) {
    topic = RegExp(
      r'''topic\s*[:=]\s*['"]?((?:title|video)-\d+)['"]?''',
    ).firstMatch(html)?.group(1);
  }
  if (sso == null || sso.isEmpty) {
    sso = RegExp(
      r'''sso\s*:\s*['"]([A-Za-z0-9_=-]+\.[A-Za-z0-9_-]+)['"]''',
    ).firstMatch(html)?.group(1);
  }
  if (topic == null || topic.isEmpty) return null;
  final title = doc.querySelector('title')?.text.trim();
  return Anime3rbComntoBootstrap(
    topic: topic,
    ssoToken: (sso != null && sso.isNotEmpty) ? sso : null,
    pageTitle: title,
  );
}

class Anime3rbCommentsService {
  Anime3rbCommentsService({
    required Anime3rbAccountService accountService,
    required Anime3rbCommentsBackend backend,
  }) : _accountService = accountService,
       _backend = backend;

  final Anime3rbAccountService _accountService;
  final Anime3rbCommentsBackend _backend;

  final Map<String, Anime3rbComntoBootstrap> _bootstrapCache =
      <String, Anime3rbComntoBootstrap>{};
  String? _cachedViewerUuid;

  String? get viewerUuid => _cachedViewerUuid;

  void clearSessionCache() {
    _bootstrapCache.clear();
    _cachedViewerUuid = null;
  }

  Future<Anime3rbComntoBootstrap> _resolveBootstrap(
    Anime3rbCommentTarget target, {
    bool forceRefresh = false,
  }) async {
    final key = target.pageUrl;
    final cached = _bootstrapCache[key];
    if (!forceRefresh &&
        cached != null &&
        (!_accountService.isSignedIn || cached.ssoToken != null)) {
      return cached;
    }
    if (!forceRefresh &&
        target.initialTopic != null &&
        target.initialTopic!.isNotEmpty &&
        (!_accountService.isSignedIn ||
            (target.initialSsoToken != null &&
                target.initialSsoToken!.isNotEmpty))) {
      final fromTarget = Anime3rbComntoBootstrap(
        topic: target.initialTopic!,
        ssoToken: target.initialSsoToken,
        pageTitle: target.title,
      );
      _bootstrapCache[key] = fromTarget;
      return fromTarget;
    }
    final uri = Uri.parse(target.pageUrl);
    final fresh = await _backend.resolveBootstrap(
      pageUri: uri,
      sessionCookie: _accountService.requestCookieHeader(),
    );
    _bootstrapCache[key] = fresh;
    return fresh;
  }

  Future<String?> _ensureBearerToken(
    Anime3rbCommentTarget target, {
    bool forceRefresh = false,
  }) async {
    if (!_accountService.isSignedIn) return null;
    final existing = _accountService.session?.comntoToken;
    if (!forceRefresh && existing != null && existing.isNotEmpty) {
      return existing;
    }
    final bootstrap = await _resolveBootstrap(
      target,
      forceRefresh: forceRefresh || existing != null,
    );
    final sso = bootstrap.ssoToken;
    if (sso == null || sso.isEmpty) {
      throw const Anime3rbAuthRequiredException(
        'تعذر الحصول على رمز التعليقات من Anime3rb، أعد تسجيل الدخول.',
      );
    }
    final exchanged = await _backend.exchangeSso(sso);
    if (exchanged == null) {
      throw const Anime3rbAuthRequiredException(
        'تعذر تفعيل جلسة التعليقات على Anime3rb، أعد تسجيل الدخول.',
      );
    }
    _cachedViewerUuid = exchanged.viewerUuid;
    await _accountService.updateComntoToken(
      token: exchanged.token,
      refreshToken: exchanged.refreshToken,
    );
    return exchanged.token;
  }

  Future<T> _withAuthRetry<T>(
    Anime3rbCommentTarget target,
    Future<T> Function(String bearerToken) run,
  ) async {
    if (!_accountService.isSignedIn) {
      throw const Anime3rbAuthRequiredException();
    }
    final token = await _ensureBearerToken(target);
    if (token == null || token.isEmpty) {
      throw const Anime3rbAuthRequiredException();
    }
    try {
      return await run(token);
    } on Anime3rbAuthRequiredException {
      final refreshed = await _ensureBearerToken(target, forceRefresh: true);
      if (refreshed == null || refreshed.isEmpty) rethrow;
      return run(refreshed);
    }
  }

  Future<Anime3rbCommentPage> loadComments(
    Anime3rbCommentTarget target, {
    Anime3rbCommentSort sort = Anime3rbCommentSort.popular,
    String? cursor,
    int limit = 20,
  }) async {
    final bootstrap = await _resolveBootstrap(target);
    String? token;
    if (_accountService.isSignedIn) {
      try {
        token = await _ensureBearerToken(target);
      } catch (_) {
        // Still allow reading public comments even if SSO fails temporarily.
      }
    }
    final page = await _backend.loadComments(
      topic: bootstrap.topic,
      pageUrl: target.pageUrl,
      sort: sort,
      cursor: cursor,
      limit: limit,
      bearerToken: token,
    );
    if (page.viewerUuid != null && page.viewerUuid!.isNotEmpty) {
      _cachedViewerUuid = page.viewerUuid;
    }
    return page;
  }

  Future<Anime3rbCommentPage> loadReplies(
    Anime3rbCommentTarget target,
    String commentUuid, {
    Anime3rbCommentSort sort = Anime3rbCommentSort.oldest,
    String? cursor,
    int limit = 20,
  }) async {
    String? token;
    if (_accountService.isSignedIn) {
      try {
        token = await _ensureBearerToken(target);
      } catch (_) {}
    }
    return _backend.loadReplies(
      commentUuid: commentUuid,
      sort: sort,
      cursor: cursor,
      limit: limit,
      bearerToken: token,
    );
  }

  Future<Anime3rbComment> createComment(
    Anime3rbCommentTarget target, {
    required String text,
    String? parentUuid,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('يرجى كتابة تعليق قبل النشر.');
    }
    final bootstrap = await _resolveBootstrap(target);
    final bodyHtml = plainTextToComntoHtml(trimmed);
    return _withAuthRetry(
      target,
      (token) => _backend.createComment(
        topic: bootstrap.topic,
        pageUrl: target.pageUrl,
        pageTitle: bootstrap.pageTitle ?? target.title,
        bodyHtml: bodyHtml,
        bearerToken: token,
        parentUuid: parentUuid,
      ),
    );
  }

  Future<Anime3rbComment> editComment(
    Anime3rbCommentTarget target, {
    required String commentUuid,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('لا يمكن حفظ تعليق فارغ.');
    }
    final bodyHtml = plainTextToComntoHtml(trimmed);
    return _withAuthRetry(
      target,
      (token) => _backend.editComment(
        commentUuid: commentUuid,
        bodyHtml: bodyHtml,
        bearerToken: token,
      ),
    );
  }

  Future<void> deleteComment(
    Anime3rbCommentTarget target, {
    required String commentUuid,
  }) => _withAuthRetry(
    target,
    (token) =>
        _backend.deleteComment(commentUuid: commentUuid, bearerToken: token),
  );

  Future<Anime3rbComment> toggleVote(
    Anime3rbCommentTarget target,
    Anime3rbComment comment,
    int value,
  ) => _withAuthRetry(target, (token) {
    if (comment.userVote == value) {
      return _backend.deleteVote(
        commentUuid: comment.uuid,
        bearerToken: token,
      );
    }
    return _backend.voteComment(
      commentUuid: comment.uuid,
      value: value,
      bearerToken: token,
    );
  });

  Future<void> reportComment(
    Anime3rbCommentTarget target, {
    required String commentUuid,
    required String reason,
    String? details,
  }) => _withAuthRetry(
    target,
    (token) => _backend.reportComment(
      commentUuid: commentUuid,
      reason: reason,
      details: details,
      bearerToken: token,
    ),
  );
}

final anime3rbCommentsServiceProvider = Provider<Anime3rbCommentsService>((ref) {
  final accountService = ref.watch(anime3rbAccountServiceProvider);
  final transport = ref.watch(anime3rbTransportProvider);
  final service = Anime3rbCommentsService(
    accountService: accountService,
    backend: HttpAnime3rbCommentsBackend(transport),
  );
  void onAccountChanged() {
    if (!accountService.isSignedIn) service.clearSessionCache();
  }

  accountService.addListener(onAccountChanged);
  ref.onDispose(() => accountService.removeListener(onAccountChanged));
  return service;
});

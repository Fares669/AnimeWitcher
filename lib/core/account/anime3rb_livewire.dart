import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../extensions/providers/anime3rb_transport.dart';

class Anime3rbAuthRequiredException implements Exception {
  const Anime3rbAuthRequiredException([
    this.message = 'يتطلب هذا الإجراء تسجيل الدخول إلى حساب Anime3rb.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class Anime3rbLivewireException implements Exception {
  const Anime3rbLivewireException(
    this.message, {
    this.statusCode,
    this.permanent = false,
  });

  final String message;
  final int? statusCode;
  final bool permanent;

  @override
  String toString() => message;
}

class Anime3rbLivewireComponent {
  const Anime3rbLivewireComponent({
    required this.name,
    required this.snapshot,
    this.id,
    this.lazyPayload,
    this.element,
  });

  final String name;
  final String snapshot;
  final String? id;
  final String? lazyPayload;
  final dom.Element? element;

  Map<String, dynamic>? get decodedSnapshot {
    try {
      final decoded = jsonDecode(snapshot);
      return decoded is Map<String, dynamic>
          ? decoded
          : (decoded is Map ? Map<String, dynamic>.from(decoded) : null);
    } catch (_) {
      return null;
    }
  }
}

class Anime3rbLivewireCallResult {
  const Anime3rbLivewireCallResult({
    this.snapshot,
    this.html,
    this.returns = const <Object?>[],
    this.rawResponse = const <String, dynamic>{},
  });

  final String? snapshot;
  final String? html;
  final List<Object?> returns;
  final Map<String, dynamic> rawResponse;
}

class Anime3rbLivewireClient {
  Anime3rbLivewireClient._();

  static bool isLoginUri(Uri? uri) {
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    return path == '/login' ||
        path.startsWith('/login/') ||
        path == '/register' ||
        path.startsWith('/forgot-password');
  }

  static bool looksAuthenticatedDocument(dom.Document doc, {Uri? finalUri}) {
    if (isLoginUri(finalUri)) return false;
    return doc.querySelector(
          'form[action*="/logout"], a[href*="/user/profile"], [wire\\:name^="profile."]',
        ) !=
        null;
  }

  static String? extractCsrfToken(dom.Document doc) {
    final meta = doc
        .querySelector('meta[name="csrf-token"]')
        ?.attributes['content']
        ?.trim();
    if (meta != null && meta.isNotEmpty) return meta;
    final script = doc
        .querySelector('script[data-csrf]')
        ?.attributes['data-csrf']
        ?.trim();
    if (script != null && script.isNotEmpty) return script;
    final input = doc
        .querySelector('input[name="_token"]')
        ?.attributes['value']
        ?.trim();
    if (input != null && input.isNotEmpty) return input;
    return null;
  }

  static Uri extractUpdateUri(dom.Document doc, Uri pageUri) {
    final attr = doc
        .querySelector('script[data-update-uri]')
        ?.attributes['data-update-uri']
        ?.trim();
    if (attr != null && attr.isNotEmpty) {
      final resolved = pageUri.resolve(attr);
      if (resolved.hasScheme && resolved.host.isNotEmpty) {
        return resolved;
      }
    }
    return pageUri.resolve('/livewire/update');
  }

  static Anime3rbLivewireComponent? findComponent(
    dom.Document doc,
    String componentName,
  ) {
    for (final el in doc.querySelectorAll('[wire\\:name]')) {
      final name = el.attributes['wire:name']?.trim();
      if (name != componentName) continue;
      final snapshot = el.attributes['wire:snapshot']?.trim();
      if (snapshot == null || snapshot.isEmpty) continue;
      final xIntersect = el.attributes['x-intersect'] ?? '';
      final lazyMatch = RegExp(
        r'''__lazyLoad\(['"]([^'"]+)['"]\)''',
      ).firstMatch(xIntersect);
      return Anime3rbLivewireComponent(
        name: name!,
        snapshot: snapshot,
        id: el.attributes['wire:id']?.trim(),
        lazyPayload: lazyMatch?.group(1),
        element: el,
      );
    }
    return null;
  }

  static Future<Anime3rbLivewireCallResult> callComponent({
    required Anime3rbTransport transport,
    required Uri pageUri,
    required String componentName,
    String? method,
    List<Object?> params = const <Object?>[],
    Map<String, Object?> updates = const <String, Object?>{},
    String? snapshotOverride,
    String? csrfOverride,
    Uri? updateUriOverride,
    Map<String, String> headers = const <String, String>{},
    String operation = 'livewire_call',
  }) async {
    var csrf = csrfOverride;
    var snapshot = snapshotOverride;
    var updateUri = updateUriOverride;

    if (csrf == null || snapshot == null || updateUri == null) {
      final pageResp = await transport.get(
        pageUri,
        headers: {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          ...headers,
        },
        operation: '${operation}_page',
      );
      if (pageResp.statusCode == 401 || isLoginUri(pageResp.finalUri)) {
        throw const Anime3rbAuthRequiredException();
      }
      if (pageResp.isCloudflareChallenge) {
        throw Anime3rbBrowserRequiredException(
          'يتطلب Anime3rb إكمال التحقق من المتصفح.',
          watchUrl: pageUri,
        );
      }
      if (!pageResp.isSuccess) {
        throw Anime3rbLivewireException(
          'Anime3rb HTTP ${pageResp.statusCode}',
          statusCode: pageResp.statusCode,
          permanent:
              pageResp.statusCode >= 400 &&
              pageResp.statusCode < 500 &&
              pageResp.statusCode != 429,
        );
      }
      final doc = html_parser.parse(pageResp.body);
      if (isLoginUri(pageResp.finalUri) ||
          (doc.querySelector('form[action*="/login"]') != null &&
              !looksAuthenticatedDocument(doc, finalUri: pageResp.finalUri))) {
        throw const Anime3rbAuthRequiredException();
      }
      csrf ??= extractCsrfToken(doc);
      updateUri ??= extractUpdateUri(doc, pageResp.finalUri ?? pageUri);
      final component = findComponent(doc, componentName);
      snapshot ??= component?.snapshot;
      // Lazy-load component automatically before invoking a real method on it.
      if (component != null &&
          component.lazyPayload != null &&
          method != null &&
          method != '__lazyLoad') {
        final lazyResult = await callComponent(
          transport: transport,
          pageUri: pageUri,
          componentName: componentName,
          method: '__lazyLoad',
          params: <Object?>[component.lazyPayload],
          snapshotOverride: snapshot,
          csrfOverride: csrf,
          updateUriOverride: updateUri,
          headers: headers,
          operation: '${operation}_lazy',
        );
        if (lazyResult.snapshot != null && lazyResult.snapshot!.isNotEmpty) {
          snapshot = lazyResult.snapshot;
        }
      }
    }

    if (csrf == null || csrf.isEmpty) {
      throw const Anime3rbLivewireException(
        'تعذر العثور على رمز الأمان CSRF من Anime3rb.',
      );
    }
    if (snapshot == null || snapshot.isEmpty) {
      throw Anime3rbLivewireException(
        'تعذر العثور على مكون $componentName في الصفحة.',
      );
    }

    final payload = <String, Object?>{
      '_token': csrf,
      'components': <Map<String, Object?>>[
        <String, Object?>{
          'snapshot': snapshot,
          'updates': updates,
          'calls': <Map<String, Object?>>[
            if (method != null)
              <String, Object?>{'path': '', 'method': method, 'params': params},
          ],
        },
      ],
    };

    final resp = await transport.post(
      updateUri,
      body: jsonEncode(payload),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/html, */*',
        'X-Livewire': '1',
        'X-CSRF-TOKEN': csrf,
        'Origin': pageUri.origin,
        'Referer': pageUri.toString(),
        ...headers,
      },
      operation: operation,
    );

    if (resp.statusCode == 401 ||
        resp.statusCode == 419 ||
        isLoginUri(resp.finalUri)) {
      throw const Anime3rbAuthRequiredException();
    }
    if (resp.statusCode == 429) {
      throw const Anime3rbRateLimitException();
    }
    if (resp.isCloudflareChallenge) {
      throw Anime3rbBrowserRequiredException(
        'يتطلب Anime3rb إكمال التحقق من المتصفح.',
        watchUrl: pageUri,
      );
    }
    if (!resp.isSuccess) {
      throw Anime3rbLivewireException(
        extractValidationError(resp.body) ??
            'تعذر تنفيذ الطلب على Anime3rb (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
        permanent: resp.statusCode >= 400 && resp.statusCode < 500,
      );
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! Map) {
      throw const Anime3rbLivewireException(
        'استجابة Livewire من Anime3rb غير صالحة.',
      );
    }
    final root = Map<String, dynamic>.from(decoded);
    final components = root['components'];
    if (components is! List || components.isEmpty || components.first is! Map) {
      return Anime3rbLivewireCallResult(rawResponse: root);
    }
    final comp = Map<String, dynamic>.from(components.first as Map);
    final nextSnapshot = comp['snapshot']?.toString();
    final effects = comp['effects'] is Map
        ? Map<String, dynamic>.from(comp['effects'] as Map)
        : const <String, dynamic>{};
    final returns = effects['returns'] is List
        ? List<Object?>.from(effects['returns'] as List)
        : const <Object?>[];
    return Anime3rbLivewireCallResult(
      snapshot: nextSnapshot,
      html: effects['html']?.toString(),
      returns: returns,
      rawResponse: root,
    );
  }

  static String? extractValidationError(String rawBody) {
    try {
      final decoded = jsonDecode(rawBody);
      if (decoded is Map) {
        final errors = decoded['errors'];
        if (errors is Map) {
          for (final value in errors.values) {
            if (value is List && value.isNotEmpty) {
              return value.first.toString();
            }
            if (value is String && value.trim().isNotEmpty) {
              return value.trim();
            }
          }
        }
        final message = decoded['message']?.toString().trim();
        if (message != null && message.isNotEmpty) return message;
      }
    } catch (_) {}
    return null;
  }
}

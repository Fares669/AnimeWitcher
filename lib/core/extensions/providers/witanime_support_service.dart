import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/witanime_account_service.dart';
import 'witanime_provider.dart';
import 'witanime_transport.dart';

enum WitanimeReportReason {
  brokenStream('الرابط لا يعمل', 'broken_link'),
  subtitleOrAudio('ترجمة أو دبلجة غير متزامنة', 'sync_issue'),
  lowQuality('جودة غير مناسبة', 'low_quality'),
  wrongEpisode('حلقة خاطئة', 'wrong_episode'),
  other('مشكلة أخرى', 'other');

  const WitanimeReportReason(this.label, this.slug);
  final String label;
  final String slug;
}

class WitanimeSubmissionResult {
  const WitanimeSubmissionResult({
    required this.accepted,
    required this.requiresBrowserVerification,
    required this.message,
    this.fallbackUri,
  });

  final bool accepted;
  final bool requiresBrowserVerification;
  final String message;
  final Uri? fallbackUri;
}

class WitanimeSupportService {
  WitanimeSupportService(this._transport, {Uri? origin})
    : _origin = origin ?? Uri.https('witanime.site');

  final WitanimeTransport _transport;
  final Uri _origin;

  String? _extractCsrf(String htmlBody) =>
      RegExp(
        r'''name=["']csrf-token["'][^>]*content=["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(htmlBody)?.group(1) ??
      RegExp(
        r'''input[^>]*name=["']_token["'][^>]*value=["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(htmlBody)?.group(1);

  bool _needsTurnstile(String body) =>
      body.contains('cf-turnstile') ||
      body.contains('challenges.cloudflare.com');

  Future<WitanimeSubmissionResult> submitEpisodeReport({
    required String targetUrl,
    required WitanimeReportReason reason,
    String details = '',
  }) async {
    final targetUri = Uri.tryParse(targetUrl.trim());
    final fallbackUri = (targetUri != null && targetUri.host == _origin.host)
        ? targetUri
        : WitanimeProvider.websiteUri('/contact');
    try {
      final page = await _transport.get(
        fallbackUri,
        operation: 'report_page',
      );
      if (page.statusCode == 403 || _needsTurnstile(page.body)) {
        return WitanimeSubmissionResult(
          accepted: false,
          requiresBrowserVerification: true,
          message: 'يتطلب إرسال البلاغ إكمال التحقق على موقع Witanime الرسمي.',
          fallbackUri: fallbackUri,
        );
      }
      final csrf = _extractCsrf(page.body);
      if (csrf == null || csrf.isEmpty) {
        return WitanimeSubmissionResult(
          accepted: false,
          requiresBrowserVerification: true,
          message: 'افتح صفحة Witanime الرسمية لإرسال البلاغ.',
          fallbackUri: fallbackUri,
        );
      }
      final resp = await _transport.post(
        _origin.replace(path: '/report'),
        body: jsonEncode({
          'url': targetUrl.trim(),
          'reason': reason.slug,
          if (details.trim().isNotEmpty) 'details': details.trim(),
        }),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-CSRF-TOKEN': csrf,
          'X-Requested-With': 'XMLHttpRequest',
          'Origin': _origin.origin,
          'Referer': fallbackUri.toString(),
        },
        operation: 'report_submit',
      );
      if (resp.isSuccess) {
        return const WitanimeSubmissionResult(
          accepted: true,
          requiresBrowserVerification: false,
          message: 'تم استلام البلاغ على Witanime بنجاح.',
        );
      }
      if (resp.statusCode == 403 || resp.statusCode == 419) {
        return WitanimeSubmissionResult(
          accepted: false,
          requiresBrowserVerification: true,
          message: 'يتطلب إرسال البلاغ إكمال التحقق على موقع Witanime الرسمي.',
          fallbackUri: fallbackUri,
        );
      }
      return WitanimeSubmissionResult(
        accepted: false,
        requiresBrowserVerification: false,
        message: 'تعذر إرسال البلاغ (HTTP ${resp.statusCode}).',
        fallbackUri: fallbackUri,
      );
    } catch (_) {
      return WitanimeSubmissionResult(
        accepted: false,
        requiresBrowserVerification: true,
        message: 'تعذر الاتصال المباشر، يمكنك إرسال البلاغ عبر الموقع الرسمي.',
        fallbackUri: fallbackUri,
      );
    }
  }

  Future<WitanimeSubmissionResult> submitSupportForm({
    required String path, // '/request' | '/contact'
    required Map<String, String> fields,
  }) async {
    final uri = WitanimeProvider.websiteUri(path);
    try {
      final page = await _transport.get(uri, operation: 'support_page');
      if (page.statusCode == 403 || _needsTurnstile(page.body)) {
        return WitanimeSubmissionResult(
          accepted: false,
          requiresBrowserVerification: true,
          message: 'يتطلب هذا النموذج إكمال التحقق على صفحة Witanime الرسمية.',
          fallbackUri: uri,
        );
      }
      final csrf = _extractCsrf(page.body);
      if (csrf == null || csrf.isEmpty) {
        return WitanimeSubmissionResult(
          accepted: false,
          requiresBrowserVerification: true,
          message: 'افتح صفحة Witanime الرسمية لإكمال الإرسال.',
          fallbackUri: uri,
        );
      }
      final resp = await _transport.post(
        uri,
        body: {'_token': csrf, ...fields},
        headers: {
          'X-CSRF-TOKEN': csrf,
          'Origin': _origin.origin,
          'Referer': uri.toString(),
        },
        operation: path == '/request' ? 'request_anime' : 'contact_support',
      );
      if (resp.isSuccess || resp.statusCode == 302) {
        return const WitanimeSubmissionResult(
          accepted: true,
          requiresBrowserVerification: false,
          message: 'تم إرسال الطلب إلى Witanime بنجاح.',
        );
      }
      if (resp.statusCode == 403 || resp.statusCode == 419) {
        return WitanimeSubmissionResult(
          accepted: false,
          requiresBrowserVerification: true,
          message: 'يتطلب هذا النموذج إكمال التحقق على صفحة Witanime الرسمية.',
          fallbackUri: uri,
        );
      }
      return WitanimeSubmissionResult(
        accepted: false,
        requiresBrowserVerification: false,
        message: 'تعذر إرسال الطلب (HTTP ${resp.statusCode}).',
        fallbackUri: uri,
      );
    } catch (_) {
      return WitanimeSubmissionResult(
        accepted: false,
        requiresBrowserVerification: true,
        message: 'تعذر الاتصال المباشر، يمكنك الإرسال عبر صفحة Witanime الرسمية.',
        fallbackUri: uri,
      );
    }
  }
}

final witanimeSupportServiceProvider = Provider<WitanimeSupportService>((ref) {
  return WitanimeSupportService(ref.watch(witanimeTransportProvider));
});

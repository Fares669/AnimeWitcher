import 'dart:convert';

/// Whether an HTTP probe response can plausibly be opened as media.
///
/// A successful status alone is not enough: file hosts commonly return a
/// branded HTML error/download page with HTTP 200. Passing that page to mpv
/// makes a source look healthy even though it cannot be demuxed.
bool isLikelyPlayableHttpResponse({
  required Uri uri,
  required int statusCode,
  String? contentType,
  List<int> bodyPrefix = const <int>[],
}) {
  if (!((statusCode >= 200 && statusCode < 400) || statusCode == 416)) {
    return false;
  }

  final path = uri.path.toLowerCase();
  final isTextManifest = path.endsWith('.m3u8') || path.endsWith('.mpd');
  final type = (contentType ?? '')
      .split(';')
      .first
      .trim()
      .toLowerCase();
  final isHtmlOrJson =
      type == 'text/html' ||
      type == 'application/xhtml+xml' ||
      type == 'application/json';
  final isUnexpectedXml =
      (type == 'application/xml' || type == 'text/xml') && !isTextManifest;
  if (isHtmlOrJson || isUnexpectedXml) {
    return false;
  }

  if (bodyPrefix.isEmpty || isTextManifest) return true;
  final prefix = utf8
      .decode(bodyPrefix.take(512).toList(growable: false), allowMalformed: true)
      .trimLeft()
      .toLowerCase();
  return !(prefix.startsWith('<!doctype html') ||
      prefix.startsWith('<html') ||
      prefix.startsWith('<head') ||
      prefix.startsWith('<?xml') ||
      prefix.contains('<title>site unavailable</title>'));
}

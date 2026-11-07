/// Native player errors may echo URLs, HTTP headers, or license responses.
/// Drop credential-bearing lines entirely, including unrecognized header names.
String redactPlaybackLog(String message) {
  final withoutUrls = message.replaceAll(_url, '[redacted-url]');
  if (_sensitiveDiagnostic.hasMatch(withoutUrls) ||
      _headerLine.hasMatch(withoutUrls)) {
    return '[Playback] Sensitive diagnostic [redacted]';
  }
  return withoutUrls;
}

final _url = RegExp(r'''(?:https?|file)://[^\s<>"']+''', caseSensitive: false);
final _headerLine = RegExp(r'(?:^|\n|\]\s*)[\w-]+:\s+', multiLine: true);
final _sensitiveDiagnostic = RegExp(
  r'\b(?:authorization|cookies?|headers?|referer|origin|drm\w*|license\w*|'
  r'cenc_decryption_key|api[-_]?key|(?:access|refresh|auth)[-_]?token)\b|'
  r'''\b(?:key|kid|secret|token)["']?\s*[:=]''',
  caseSensitive: false,
);

/// Also catches known values echoed without a URL/header/key label by a backend.
class PlaybackLogRedactor {
  final _secrets = <String>{};

  void addSecrets(Iterable<String?> values) {
    _secrets.addAll(
      values.whereType<String>().where((value) => value.isNotEmpty),
    );
  }

  String redact(String message) {
    var result = redactPlaybackLog(message);
    final secrets = _secrets.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final value in secrets) {
      result = result.replaceAll(value, '[redacted]');
    }
    return result;
  }
}

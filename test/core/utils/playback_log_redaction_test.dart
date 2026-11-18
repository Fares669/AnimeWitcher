import 'package:animewitcher/core/utils/playback_log_redaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('URL redaction includes paths, user-info, query and proxy payloads', () {
    final output = redactPlaybackLog(
      'Opening HTTPS://user:password@video.test/secret-path?token=secret '
      'and http://127.0.0.1/proxy?url=encoded-secret&h=encoded-headers',
    );
    expect(output, 'Opening [redacted-url] and [redacted-url]');
  });

  for (final message in [
    '[MPV/error] Authorization: Bearer secret',
    '[MPV/error] X-Custom-Header: secret',
    'Cookie: session=secret',
    'Player: Setting http-header-fields: X-Custom: secret',
    '[DRM] Injecting cenc_decryption_key: secret',
    '[DRM] base64url decode failed for "secret"',
    'license response {"keys":[{"kid":"secret","k":"secret"}]}',
    'token=secret',
  ]) {
    test('suppresses untrusted sensitive diagnostic: $message', () {
      expect(redactPlaybackLog(message), isNot(contains('secret')));
      expect(redactPlaybackLog(message), contains('redacted'));
    });
  }

  test('backend echoes of known values are redacted without labels', () {
    final redactor = PlaybackLogRedactor()
      ..addSecrets(['opaque-private-value', 'opaque-private', null]);
    expect(
      redactor.redact('Failed opaque-private-value at offset 42'),
      'Failed [redacted] at offset 42',
    );
    expect(
      redactor.redact('Buffering 5 seconds, status 403'),
      'Buffering 5 seconds, status 403',
    );
  });

  test('short known credential values are also redacted', () {
    final redactor = PlaybackLogRedactor()..addSecrets(['XYZ', '']);
    expect(
      redactor.redact('server rejected XYZ'),
      'server rejected [redacted]',
    );
  });
}

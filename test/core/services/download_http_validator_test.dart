import 'package:animewitcher/core/services/download_http_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const modified = 'Wed, 21 Oct 2015 07:28:00 GMT';
  const strongDate = 'Wed, 21 Oct 2015 07:29:00 GMT';

  test('missing response headers have no If-Range validator', () {
    expect(downloadIfRangeValidator(null), isNull);
    expect(downloadIfRangeValidator({}), isNull);
    expect(downloadIfRangeValidator({'Date': strongDate}), isNull);
  });

  test('strong ETag names are case-insensitive and values stay unchanged', () {
    for (final name in ['ETag', 'etag', 'eTaG']) {
      for (final value in ['"resource"', '""', ' \t"resource"\t ']) {
        expect(downloadIfRangeValidator({name: value}), value);
      }
    }
  });

  test('a strong ETag takes precedence over invalid date headers', () {
    expect(
      downloadIfRangeValidator({
        'ETag': '"resource"',
        'Last-Modified': 'invalid',
        'Date': 'invalid',
      }),
      '"resource"',
    );
  });

  test('ETag opaque data admits exactly RFC 9110 etagc bytes', () {
    for (var byte = 0; byte <= 0x100; byte++) {
      final value = '"${String.fromCharCode(byte)}"';
      final allowed =
          byte == 0x21 ||
          (byte >= 0x23 && byte <= 0x7e) ||
          (byte >= 0x80 && byte <= 0xff);
      expect(
        downloadIfRangeValidator({'ETag': value}),
        allowed ? value : null,
        reason: 'ETag byte 0x${byte.toRadixString(16)}',
      );
    }
  });

  for (final value in <String>[
    '',
    ' ',
    'bare-tag',
    '*',
    'W/"resource"',
    'w/"resource"',
    ' W/"resource" ',
    '"unterminated',
    '"one""two"',
    '"one", "two"',
    '"space inside"',
    '"tab\tinside"',
    '"line\rbreak"',
    '"line\nbreak"',
    '"resource"\n',
    '\n"resource"',
    '\u00a0"resource"',
    '"resource"\u00a0',
    '"non-byte-\u0100"',
    '"non-byte-\u{1f600}"',
    '"surrogate-\ud800"',
  ]) {
    test('invalid ETag ${value.codeUnits} never falls back to dates', () {
      expect(
        downloadIfRangeValidator({
          'ETag': value,
          'Last-Modified': modified,
          'Date': strongDate,
        }),
        isNull,
      );
    });
  }

  test('duplicate ETag spellings cannot hide a weak value', () {
    for (final headers in [
      {'ETag': 'W/"weak"', 'etag': '"strong"'},
      {'ETag': '"strong"', 'etag': 'W/"weak"'},
      {'ETag': '"strong"', 'etag': '"strong"'},
    ]) {
      expect(downloadIfRangeValidator(headers), isNull);
    }
  });

  test('qualified Last-Modified is returned exactly as received', () {
    for (final value in [modified, ' \t$modified\t ']) {
      expect(
        downloadIfRangeValidator({'lAsT-mOdIfIeD': value, 'dAtE': strongDate}),
        value,
      );
    }
  });

  for (final date in <String?>[
    null,
    '',
    'invalid',
    'Wed, 21 Oct 2015 07:27:00 GMT',
    modified,
    'Wed, 21 Oct 2015 07:28:01 GMT',
    'Wed, 21 Oct 2015 07:28:59 GMT',
  ]) {
    test('unqualified Date $date cannot promote Last-Modified', () {
      expect(
        downloadIfRangeValidator({'Last-Modified': modified, 'Date': ?date}),
        isNull,
      );
    });
  }

  for (final value in <String>[
    '',
    'invalid',
    '2015-10-21T07:28:00Z',
    'Wed, 21 Oct 2015 07:28:00 PST',
    'Wed, 21 Oct 2015 07:28:00 GMT trailing',
    'Tue, 21 Oct 2015 07:28:00 GMT',
    'Wed, 32 Oct 2015 07:28:00 GMT',
    'Wed, 21 Oct 2015 24:00:00 GMT',
    'Wed, 21 Oct 2015 07:60:00 GMT',
    'Wed, 21 Oct 2015 07:28:61 GMT',
    'Wed, 21 Oct 2015 07:28:00 GMT\n',
    'Wednesday, 21-Oct-15 07:28:00 GMT',
    'Wed Oct 21 07:28:00 2015',
  ]) {
    test('unsafe date ${value.codeUnits} cannot qualify a validator', () {
      expect(
        downloadIfRangeValidator({'Last-Modified': value, 'Date': strongDate}),
        isNull,
      );
      expect(
        downloadIfRangeValidator({'Last-Modified': modified, 'Date': value}),
        isNull,
      );
    });
  }

  test('duplicate date fields cannot qualify a date validator', () {
    expect(
      downloadIfRangeValidator({
        'Last-Modified': modified,
        'last-modified': modified,
        'Date': strongDate,
      }),
      isNull,
    );
    expect(
      downloadIfRangeValidator({
        'Last-Modified': modified,
        'Date': strongDate,
        'date': strongDate,
      }),
      isNull,
    );
  });
}

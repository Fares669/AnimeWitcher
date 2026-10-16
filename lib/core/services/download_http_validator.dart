import 'dart:io';

final _strongETag = RegExp(r'^[ \t]*"[\x21\x23-\x7e\x80-\xff]*"[ \t]*$');
final _httpWhitespace = RegExp(r'^[ \t]+|[ \t]+$');

/// Returns an unchanged response validator eligible for If-Range, or null.
///
/// No validator means callers must retain their full byte-verification path.
String? downloadIfRangeValidator(Map<String, String>? headers) {
  if (headers == null) return null;
  final values = <String, String>{};
  final duplicates = <String>{};
  for (final entry in headers.entries) {
    final name = entry.key.toLowerCase();
    if (!const {'etag', 'last-modified', 'date'}.contains(name)) continue;
    if (values.containsKey(name)) duplicates.add(name);
    values[name] = entry.value;
  }
  final etag = values['etag'];
  if (etag != null) {
    // RFC 9110 13.1.5 forbids date fallback when an entity tag is present.
    return !duplicates.contains('etag') && _strongETag.stringMatch(etag) == etag
        ? etag
        : null;
  }
  if (duplicates.isNotEmpty) return null;
  final modified = values['last-modified'];
  final modifiedAt = _parseValidatorDate(modified);
  final responseAt = _parseValidatorDate(values['date']);
  if (modifiedAt == null || responseAt == null) return null;
  // RFC 9110 8.8.2.2: without same-clock evidence, allow a clock-skew margin.
  return responseAt.difference(modifiedAt) >= const Duration(seconds: 60)
      ? modified
      : null;
}

DateTime? _parseValidatorDate(String? raw) {
  if (raw == null) return null;
  final value = raw.replaceAll(_httpWhitespace, '');
  // Senders must use IMF-fixdate; do not rewrite obsolete dates for If-Range.
  if (value.length != 29 || value[3] != ',') return null;
  try {
    final parsed = HttpDate.parse(value);
    // HttpDate.parse otherwise accepts overflowing fields and wrong weekdays.
    return HttpDate.format(parsed) == value ? parsed : null;
  } on HttpException {
    return null;
  } on FormatException {
    return null;
  }
}

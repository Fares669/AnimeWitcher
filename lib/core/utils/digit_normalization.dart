final _localizedDigits = RegExp('[٠-٩۰-۹]');

/// Replaces Arabic-Indic and Eastern Arabic-Indic digits with ASCII digits.
String normalizeLocalizedDigits(String value) {
  return value.replaceAllMapped(_localizedDigits, (match) {
    final code = value.codeUnitAt(match.start);
    final zero = code < 0x06f0 ? 0x0660 : 0x06f0;
    return String.fromCharCode(0x30 + code - zero);
  });
}

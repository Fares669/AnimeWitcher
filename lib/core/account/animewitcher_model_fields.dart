/// Copies a payload map to string keys; non-map fields have no entries.
Map<String, dynamic> stringMap(dynamic raw) {
  if (raw is! Map) return const <String, dynamic>{};
  return raw.map<String, dynamic>(
    (key, value) => MapEntry(key.toString(), value),
  );
}

String text(dynamic raw) => raw?.toString().trim() ?? '';

String? optionalText(dynamic raw) {
  final value = text(raw);
  return value.isEmpty ? null : value;
}

DateTime? localDate(dynamic raw) {
  if (raw is DateTime) return raw.toLocal();
  final parsed = DateTime.tryParse(raw?.toString() ?? '');
  return parsed?.toLocal();
}

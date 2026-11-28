import 'dart:convert';

import '../../../../core/storage/storage_service.dart';

/// Best-effort lookup, retaining each resolver's own value parser.
T? readSkipId<T>(
  StorageService? storage,
  String storageKey,
  String key,
  T? Function(Object?) parse,
) {
  try {
    final raw = storage?.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map ? parse(decoded[key]) : null;
  } catch (_) {
    return null;
  }
}

/// Best-effort ID upsert, keeping recently written entries last.
Future<void> saveSkipId(
  StorageService? storage,
  String storageKey,
  String key,
  int maxEntries,
  Object Function() buildValue,
) async {
  if (storage == null) return;
  try {
    final raw = storage.getString(storageKey);
    final decoded = raw == null || raw.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw);
    final all = decoded is Map
        ? decoded.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    all.remove(key);
    all[key] = buildValue();
    while (all.length > maxEntries) {
      all.remove(all.keys.first);
    }
    await storage.setString(storageKey, jsonEncode(all));
  } catch (_) {}
}

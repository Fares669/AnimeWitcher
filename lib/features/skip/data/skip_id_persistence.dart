import 'dart:convert';

import '../../../../core/storage/storage_service.dart';

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

/// Read a boolean in the account's older JSON/Firestore formats.
bool readAnimeWitcherPayloadBool(Object? raw, bool fallback) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is! String) return fallback;
  return switch (raw.trim().toLowerCase()) {
    'true' || '1' => true,
    'false' || '0' => false,
    _ => fallback,
  };
}

/// Firebase response provider IDs, unique and in their original order.
List<String> readFirebaseProviderIds(Object? raw) {
  if (raw is! Iterable) return const <String>[];
  final providers = <String>{};
  for (final entry in raw) {
    if (entry is! Map) continue;
    final provider = entry['providerId']?.toString().trim() ?? '';
    if (provider.isNotEmpty) providers.add(provider);
  }
  return providers.toList(growable: false);
}

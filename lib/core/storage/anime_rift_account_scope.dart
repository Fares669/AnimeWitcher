import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Selects the local Rift data partition using the identity returned by Rift.
///
/// A guest uses the original storage keys, preserving existing local data.
/// Linked users get distinct hashed partitions. The raw user id and account
/// token are never written to a local-library or history storage key.
class AnimeRiftLocalAccountScope {
  AnimeRiftLocalAccountScope._();

  static String? _accountHash;

  static String? get accountHash => _accountHash;

  static void activate(String accountId) {
    final normalized = accountId.trim();
    if (normalized.isEmpty || normalized.length > 512) {
      throw ArgumentError.value(null, 'accountId', 'Invalid account identity');
    }
    _accountHash = sha256.convert(utf8.encode(normalized)).toString();
  }

  static void reset() {
    _accountHash = null;
  }

  static String storageNamespace(String providerId) {
    final hash = _accountHash;
    return providerId == 'com.animerift.provider' && hash != null
        ? '$providerId:account:$hash'
        : providerId;
  }
}

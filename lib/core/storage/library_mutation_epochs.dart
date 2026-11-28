/// In-memory revisions for rejecting stale library responses in one service.
final class LibraryMutationEpochs {
  LibraryMutationEpochs(this._canonicalWorkUrl);

  final String Function(String) _canonicalWorkUrl;
  final _epochs = <String, int>{};

  String _key(String accountId, String workUrl) =>
      '$accountId|${_canonicalWorkUrl(workUrl)}';

  void bump(String accountId, String workUrl) {
    final key = _key(accountId, workUrl);
    _epochs[key] = (_epochs[key] ?? 0) + 1;
  }

  int current(String accountId, String workUrl) =>
      _epochs[_key(accountId, workUrl)] ?? 0;

  /// Captures the current revisions before the caller starts an async read.
  bool Function(String accountId, String url) snapshotGuard() {
    final before = Map<String, int>.from(_epochs);
    return (accountId, url) {
      final key = _key(accountId, url);
      return (_epochs[key] ?? 0) != (before[key] ?? 0);
    };
  }
}

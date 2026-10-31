import 'package:flutter/foundation.dart';

List<List<int>> mangaReaderOrderedPreloadBatches({
  required int pageCount,
  required int initialPage,
  required int batchSize,
}) {
  if (pageCount <= 0) return const <List<int>>[];
  final safeStart = initialPage.clamp(0, pageCount - 1).toInt();
  final width = batchSize.clamp(1, 20).toInt();
  final batches = <List<int>>[];
  // Forward from the page reading starts at: those pages matter first.
  for (var start = safeStart; start < pageCount; start += width) {
    final end = (start + width).clamp(0, pageCount).toInt();
    batches.add(<int>[for (var index = start; index < end; index++) index]);
  }
  // Then the pages before it, nearest first. A resumed chapter — or the
  // previous chapter of a connected chapter stream — is read by scrolling
  // back, and those pages must be loadable too, not placeholder forever.
  for (var end = safeStart; end > 0; end -= width) {
    final start = (end - width).clamp(0, safeStart).toInt();
    batches.add(<int>[for (var index = start; index < end; index++) index]);
  }
  return batches;
}

class MangaReaderLoadBatchController extends ChangeNotifier {
  MangaReaderLoadBatchController({
    required int pageCount,
    required int initialPage,
    required int batchSize,
  }) : _batches = mangaReaderOrderedPreloadBatches(
         pageCount: pageCount,
         initialPage: initialPage,
         batchSize: batchSize,
       ) {
    if (_batches.isNotEmpty) {
      _unlocked.addAll(_batches.first);
      final start = initialPage.clamp(0, pageCount - 1).toInt();
      _backwardStart = _batches.indexWhere((batch) => batch.last < start);
      _backwardIndex = _backwardStart;
      if (_backwardIndex >= 0) _unlocked.addAll(_batches[_backwardIndex]);
    }
  }

  final List<List<int>> _batches;
  final Set<int> _unlocked = <int>{};
  final Set<int> _settled = <int>{};
  int _forwardIndex = 0;
  int _backwardStart = -1;
  int _backwardIndex = -1;

  bool canLoad(int pageIndex) => _unlocked.contains(pageIndex);

  @visibleForTesting
  Set<int> get unlockedPages => Set<int>.unmodifiable(_unlocked);

  void markSettled(int pageIndex) {
    if (_batches.isEmpty || !_settled.add(pageIndex)) return;
    final previousCount = _unlocked.length;
    _advanceBackward();
    _advanceForward();
    if (_unlocked.length != previousCount) notifyListeners();
  }

  void _advanceForward() {
    final end = _backwardStart < 0 ? _batches.length : _backwardStart;
    while (_forwardIndex < end &&
        _batches[_forwardIndex].every(_settled.contains)) {
      _forwardIndex++;
      if (_forwardIndex < end) _unlocked.addAll(_batches[_forwardIndex]);
    }
  }

  void _advanceBackward() {
    while (_backwardIndex >= 0 &&
        _backwardIndex < _batches.length &&
        _batches[_backwardIndex].every(_settled.contains)) {
      _backwardIndex++;
      if (_backwardIndex < _batches.length) {
        _unlocked.addAll(_batches[_backwardIndex]);
      }
    }
  }
}

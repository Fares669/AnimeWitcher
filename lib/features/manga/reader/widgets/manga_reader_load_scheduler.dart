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
  }) : _pageCount = pageCount,
       _width = batchSize.clamp(1, 20).toInt() {
    if (_pageCount <= 0) return;

    final start = initialPage.clamp(0, _pageCount - 1).toInt();
    _forwardStart = start;
    _backwardEnd = start;
    _unlockRange(_forwardStart, _forwardRangeEnd(_forwardStart));
    _unlockRange(_backwardRangeStart(_backwardEnd), _backwardEnd);
  }

  final int _pageCount;
  final int _width;
  final Set<int> _unlocked = <int>{};
  final Set<int> _settled = <int>{};

  // The active batches are contiguous ranges. Keep only their frontiers
  // instead of materializing every batch in the chapter when the reader opens.
  int _forwardStart = 0;
  int _backwardEnd = 0;

  bool canLoad(int pageIndex) => _unlocked.contains(pageIndex);

  @visibleForTesting
  Set<int> get unlockedPages => Set<int>.unmodifiable(_unlocked);

  void markSettled(int pageIndex) {
    if (_pageCount <= 0 || !_settled.add(pageIndex)) return;
    final previousCount = _unlocked.length;
    _advanceBackward();
    _advanceForward();
    if (_unlocked.length != previousCount) notifyListeners();
  }

  int _forwardRangeEnd(int start) =>
      _pageCount - start < _width ? _pageCount : start + _width;

  int _backwardRangeStart(int end) => end < _width ? 0 : end - _width;

  bool _isRangeSettled(int start, int end) {
    for (var index = start; index < end; index++) {
      if (!_settled.contains(index)) return false;
    }
    return true;
  }

  void _unlockRange(int start, int end) {
    for (var index = start; index < end; index++) {
      _unlocked.add(index);
    }
  }

  void _advanceForward() {
    while (_forwardStart < _pageCount) {
      final end = _forwardRangeEnd(_forwardStart);
      if (!_isRangeSettled(_forwardStart, end)) return;
      _forwardStart = end;
      _unlockRange(end, _forwardRangeEnd(end));
    }
  }

  void _advanceBackward() {
    while (_backwardEnd > 0) {
      final start = _backwardRangeStart(_backwardEnd);
      if (!_isRangeSettled(start, _backwardEnd)) return;
      _backwardEnd = start;
      _unlockRange(_backwardRangeStart(start), start);
    }
  }
}

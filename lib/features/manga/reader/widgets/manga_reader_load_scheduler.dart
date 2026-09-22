import 'package:flutter/foundation.dart';

@visibleForTesting
List<List<int>> mangaReaderOrderedPreloadBatches({
  required int pageCount,
  required int initialPage,
  required int batchSize,
}) {
  if (pageCount <= 0) return const <List<int>>[];
  final safeStart = initialPage.clamp(0, pageCount - 1).toInt();
  final width = batchSize.clamp(1, 20).toInt();
  final batches = <List<int>>[];
  for (var start = safeStart; start < pageCount; start += width) {
    final end = (start + width).clamp(0, pageCount).toInt();
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
    if (_batches.isNotEmpty) _unlocked.addAll(_batches.first);
  }

  final List<List<int>> _batches;
  final Set<int> _unlocked = <int>{};
  final Set<int> _settled = <int>{};
  int _batchIndex = 0;

  bool canLoad(int pageIndex) => _unlocked.contains(pageIndex);

  @visibleForTesting
  Set<int> get unlockedPages => Set<int>.unmodifiable(_unlocked);

  void markSettled(int pageIndex) {
    if (_batches.isEmpty || _batchIndex >= _batches.length) return;
    final current = _batches[_batchIndex];
    if (!current.contains(pageIndex)) return;
    _settled.add(pageIndex);
    if (!current.every(_settled.contains)) return;

    _batchIndex++;
    if (_batchIndex >= _batches.length) return;
    _unlocked.addAll(_batches[_batchIndex]);
    notifyListeners();
  }
}

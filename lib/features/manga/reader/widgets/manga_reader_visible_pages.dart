/// Keeps viewport samples for one reader session without scheduling callbacks.
final class MangaReaderVisiblePages {
  final _fractions = <int, double>{};
  final _seenRounds = <int, int>{};
  int _round = 0;

  bool get isEmpty => _fractions.isEmpty;
  double fractionOf(int pageIndex) => _fractions[pageIndex] ?? 0;

  void record(int pageIndex, double fraction) {
    _fractions[pageIndex] = fraction;
    _seenRounds[pageIndex] = _round + 1;
  }

  // A recycled page must stop outweighing the visible pages following it.
  void advanceRound() {
    _round++;
    _fractions.removeWhere(
      (index, _) => (_seenRounds[index] ?? -1) < _round - 1,
    );
  }

  int? get mostVisiblePage {
    int? page;
    var fraction = 0.0;
    for (final entry in _fractions.entries) {
      if (entry.value > fraction) {
        page = entry.key;
        fraction = entry.value;
      }
    }
    return page;
  }
}

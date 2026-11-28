import 'digit_normalization.dart';

final _decimalToken = RegExp(r'[0-9]+(?:[.][0-9]+)?');

/// Reads the first unsigned, dot-decimal score after normalizing Arabic digits.
double? parsePositiveRatingScore(String? raw) {
  final normalized = normalizeLocalizedDigits((raw ?? '').trim());
  if (normalized.isEmpty) return null;
  final token = _decimalToken.stringMatch(normalized);
  final score = token == null ? null : double.tryParse(token);
  return score == null || score <= 0 ? null : score;
}

String formatRatingScore(double score) => score
    .toStringAsFixed(2)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'[.]$'), '');

import 'package:animewitcher/core/utils/digit_normalization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('changes only Arabic-Indic and Eastern Arabic-Indic digits', () {
    expect(
      normalizeLocalizedDigits('🎬 الحلقة ٠١٢٣٤٥٦٧٨٩ / ۰۱۲۳۴۵۶۷۸۹'),
      '🎬 الحلقة 0123456789 / 0123456789',
    );
    expect(normalizeLocalizedDigits('１２:٤٫۵'), '１２:4٫5');
    expect(normalizeLocalizedDigits('12'), '12');
    expect(normalizeLocalizedDigits(''), '');
  });
}

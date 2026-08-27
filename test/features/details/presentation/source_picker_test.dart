import 'package:animewitcher/features/details/presentation/source_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sourcePickerHeader', () {
    test('uses the server episode label instead of a generic source prompt', () {
      expect(sourcePickerHeader('الحلقة 10', isArabic: true), 'الحلقة 10');
      expect(sourcePickerHeader('الفيلم', isArabic: true), 'الفيلم');
      expect(sourcePickerHeader('مترجم', isArabic: true), 'مترجم');
    });

    test('keeps the localized generic prompt when no episode is available', () {
      expect(sourcePickerHeader(null, isArabic: true), 'اختر المصدر');
      expect(sourcePickerHeader('  ', isArabic: false), 'Choose source');
    });
  });
}

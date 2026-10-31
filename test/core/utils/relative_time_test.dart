import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/utils/relative_time.dart';

void main() {
  final now = DateTime(2026, 8, 28, 12);

  test('uses dual Arabic forms for two units', () {
    expect(
      formatArabicRelativeTime(
        now.subtract(const Duration(hours: 2)),
        now: now,
      ),
      'منذ ساعتين',
    );
    expect(
      formatArabicRelativeTime(
        now.subtract(const Duration(days: 2)),
        now: now,
      ),
      'منذ يومين',
    );
  });

  test('keeps singular hour after eleven', () {
    expect(
      formatArabicRelativeTime(
        now.subtract(const Duration(hours: 12)),
        now: now,
      ),
      'منذ 12 ساعة',
    );
  });

  test('uses plural hours from three to ten', () {
    expect(
      formatArabicRelativeTime(
        now.subtract(const Duration(hours: 5)),
        now: now,
      ),
      'منذ 5 ساعات',
    );
  });

  test('returns empty when the date is missing', () {
    expect(formatArabicRelativeTime(null, now: now), '');
  });

  test('shows a calendar date from thirty days on', () {
    expect(
      formatArabicRelativeTime(
        now.subtract(const Duration(days: 45)),
        now: now,
      ),
      '14/07/2026',
    );
    expect(
      formatArabicRelativeTime(
        now.subtract(const Duration(days: 29)),
        now: now,
      ),
      'منذ 29 يوم',
    );
  });
}

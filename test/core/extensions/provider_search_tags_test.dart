import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty tags preserve legacy filter serialization', () {
    expect(const ProviderSearchFilters().toJson().keys, [
      'statuses',
      'types',
      'ageRatings',
      'years',
      'seasons',
      'genres',
      'sort',
    ]);
    expect(const ProviderSearchFilters().tags, isEmpty);
  });
  test(
    'tags remain separate from genres through copying and serialization',
    () {
      const value = ProviderSearchFilters(tags: {'بطل مضاد'}, genres: {'أكشن'});
      final copied = value.copyWith(sort: 'year_desc');
      expect(copied.count, 2);
      expect(copied.tags, {'بطل مضاد'});
      expect(copied.genres, {'أكشن'});
      expect(copied.toJson()['tags'], ['بطل مضاد']);
      expect(copied.copyWith(tags: {}).count, 1);
    },
  );
  test('tag-only provider options are available and parsed independently', () {
    final options = ProviderSearchFilterOptions.fromJson({
      'tags': [' Theme ', 'Theme'],
    });
    expect(options.isEmpty, isFalse);
    expect(options.tags, ['Theme']);
    expect(options.genres, isEmpty);
  });
}

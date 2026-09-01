import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/home/presentation/home_section_titles.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item(String title) {
  return MultimediaItem(
    title: title,
    url: 'https://example.test/$title',
    posterUrl: '',
  );
}

void main() {
  test('detects فصول جديدة without matching الحلقات الجديدة', () {
    expect(isNewChaptersHomeSectionTitle('فصول جديدة'), isTrue);
    expect(isNewChaptersHomeSectionTitle('الفصول الجديدة'), isTrue);
    expect(isNewChaptersHomeSectionTitle('أحدث الفصول'), isTrue);
    expect(isNewChaptersHomeSectionTitle('New Chapters'), isTrue);
    expect(isNewChaptersHomeSectionTitle('latest chapters'), isTrue);

    expect(isNewChaptersHomeSectionTitle('الحلقات الجديدة'), isFalse);
    expect(isNewChaptersHomeSectionTitle('آخر الأعمال المضافة'), isFalse);
    expect(isNewChaptersHomeSectionTitle('الانميشن الاكثر مشاهدة'), isFalse);
    expect(isNewChaptersHomeSectionTitle('Trending'), isFalse);
  });

  test('home hides New Chapters and Trending rails only', () {
    final data = <String, List<MultimediaItem>>{
      'Trending': <MultimediaItem>[_item('Hero')],
      'الحلقات الجديدة': <MultimediaItem>[_item('Episode Show')],
      'فصول جديدة': <MultimediaItem>[
        _item('RxOiaLyVTBIUObsclHrw'),
        _item('zQY3tAdwWaVZ5O31zMVd'),
      ],
      'آخر الأعمال المضافة': <MultimediaItem>[_item('Added Show')],
    };

    final visible = visibleHomeRailEntries(
      data,
    ).map((entry) => entry.key).toList(growable: false);

    expect(visible, <String>['الحلقات الجديدة', 'آخر الأعمال المضافة']);
    expect(homeHeroMovies(data)?.first.title, 'Hero');
  });

  test('hidden New Chapters rail is not promoted into the hero', () {
    final data = <String, List<MultimediaItem>>{
      'فصول جديدة': <MultimediaItem>[_item('RxOiaLyVTBIUObsclHrw')],
      'آخر الأعمال المضافة': <MultimediaItem>[_item('Added Show')],
    };

    expect(homeHeroMovies(data)?.first.title, 'Added Show');
    expect(
      visibleHomeRailEntries(data).map((entry) => entry.key),
      <String>['آخر الأعمال المضافة'],
    );
  });
}

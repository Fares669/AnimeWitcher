import 'dart:collection';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/player/presentation/episode_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

Episode _row(String url, DubStatus variant, {bool filler = false}) =>
    Episode(name: url, url: url, dubStatus: variant, isFiller: filler);

class _CountReads extends ListBase<Episode> {
  _CountReads(this.rows);
  final List<Episode> rows;
  int reads = 0;
  @override
  int get length => rows.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  Episode operator [](int index) {
    reads++;
    return rows[index];
  }

  @override
  void operator []=(int index, Episode value) =>
      throw UnsupportedError('read only');
}

void main() {
  test('the first matching URL in the active variant anchors navigation', () {
    final anchor = _row('start', DubStatus.dubbed, filler: true);
    final filler = _row('filler', DubStatus.dubbed, filler: true);
    final story = _row('end', DubStatus.dubbed);
    final rows = [
      _row('start', DubStatus.subbed),
      _row('before', DubStatus.dubbed),
      anchor,
      filler,
      _row('end', DubStatus.subbed),
      story,
    ];
    expect(
      nextStoryEpisode(
        episodes: rows,
        currentEpisode: anchor,
        currentEpisodeUrl: 'other',
      ),
      same(story),
    );
    expect(
      adjacentEpisode(
        episodes: rows,
        currentEpisode: story,
        currentEpisodeUrl: 'other',
        offset: -2,
      ),
      same(anchor),
    );
    expect(
      adjacentEpisode(
        episodes: rows,
        currentEpisode: anchor,
        currentEpisodeUrl: 'other',
        offset: 2,
      ),
      same(story),
    );
    expect(
      episodeAtOffsetInVariant(
        rows,
        currentUrl: 'start',
        variant: DubStatus.dubbed,
      ),
      same(filler),
    );
    expect(
      episodeAtOffsetInVariant(
        rows,
        currentUrl: 'missing',
        variant: DubStatus.dubbed,
      ),
      isNull,
    );
  });

  test(
    'a long run of filler is scanned once without rebuilding the dub list',
    () {
      final anchor = _row('first', DubStatus.dubbed);
      final story = _row('last', DubStatus.dubbed);
      final rows = _CountReads([
        anchor,
        for (var i = 0; i < 200; i++) ...[
          _row('other-$i', DubStatus.subbed),
          _row('filler-$i', DubStatus.dubbed, filler: true),
        ],
        story,
      ]);
      expect(
        nextStoryEpisode(
          episodes: rows,
          currentEpisode: anchor,
          currentEpisodeUrl: '',
        ),
        same(story),
      );
      expect(rows.reads, lessThanOrEqualTo(rows.length + 1));
    },
  );
}

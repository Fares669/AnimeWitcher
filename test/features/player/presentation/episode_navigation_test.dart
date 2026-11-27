import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/player/presentation/episode_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

Episode _episode(int number, {DubStatus dubStatus = DubStatus.none}) {
  return Episode(
    name: 'Episode $number',
    url: 'https://example.test/episode-$number-$dubStatus',
    episode: number,
    dubStatus: dubStatus,
  );
}

void main() {
  test('returns no previous episode at the beginning of the sequence', () {
    final first = _episode(1);

    expect(
      adjacentEpisode(
        episodes: [first, _episode(2)],
        currentEpisode: first,
        currentEpisodeUrl: first.url,
        offset: -1,
      ),
      isNull,
    );
  });

  test('returns no next episode at the end of the sequence', () {
    final last = _episode(2);

    expect(
      adjacentEpisode(
        episodes: [_episode(1), last],
        currentEpisode: last,
        currentEpisodeUrl: last.url,
        offset: 1,
      ),
      isNull,
    );
  });

  test('returns both neighbors from a middle episode', () {
    final first = _episode(1);
    final middle = _episode(2);
    final last = _episode(3);
    final episodes = [first, middle, last];

    expect(
      adjacentEpisode(
        episodes: episodes,
        currentEpisode: middle,
        currentEpisodeUrl: middle.url,
        offset: -1,
      ),
      same(first),
    );
    expect(
      adjacentEpisode(
        episodes: episodes,
        currentEpisode: middle,
        currentEpisodeUrl: middle.url,
        offset: 1,
      ),
      same(last),
    );
  });

  test('returns no neighbor for a single-episode sequence', () {
    final only = _episode(1);

    expect(
      adjacentEpisode(
        episodes: [only],
        currentEpisode: only,
        currentEpisodeUrl: only.url,
        offset: -1,
      ),
      isNull,
    );
    expect(
      adjacentEpisode(
        episodes: [only],
        currentEpisode: only,
        currentEpisodeUrl: only.url,
        offset: 1,
      ),
      isNull,
    );
  });

  test('resolves the current row from its url when the episode is missing', () {
    final first = _episode(1);
    final second = _episode(2);

    expect(
      adjacentEpisode(
        episodes: [first, second],
        currentEpisode: null,
        currentEpisodeUrl: first.url,
        offset: 1,
      ),
      same(second),
    );
  });

  test('moves only within the active subtitle or dub variant', () {
    final subbedFirst = _episode(1, dubStatus: DubStatus.subbed);
    final dubbedFirst = _episode(1, dubStatus: DubStatus.dubbed);
    final subbedSecond = _episode(2, dubStatus: DubStatus.subbed);
    final dubbedSecond = _episode(2, dubStatus: DubStatus.dubbed);
    final episodes = [subbedFirst, dubbedFirst, subbedSecond, dubbedSecond];

    expect(
      adjacentEpisode(
        episodes: episodes,
        currentEpisode: subbedFirst,
        currentEpisodeUrl: subbedFirst.url,
        offset: 1,
      ),
      same(subbedSecond),
    );
    expect(
      adjacentEpisode(
        episodes: episodes,
        currentEpisode: dubbedSecond,
        currentEpisodeUrl: dubbedSecond.url,
        offset: -1,
      ),
      same(dubbedFirst),
    );
  });

  test('chrome projection keeps duplicate URL and variant ordering', () {
    Episode row(String url, DubStatus variant, {bool filler = false}) =>
        Episode(name: url, url: url, dubStatus: variant, isFiller: filler);
    final prior = row('previous', DubStatus.subbed);
    final otherAnchor = row('anchor', DubStatus.dubbed);
    final anchor = row('anchor', DubStatus.subbed);
    final otherNext = row('wrong-next', DubStatus.dubbed);
    final filler = row('filler', DubStatus.subbed, filler: true);
    final sameAnchorAgain = row('anchor', DubStatus.subbed, filler: true);
    final otherStory = row('wrong-story', DubStatus.dubbed);
    final story = row('story', DubStatus.subbed);
    final list = [
      prior,
      otherAnchor,
      anchor,
      otherNext,
      filler,
      sameAnchorAgain,
      otherStory,
      story,
    ];

    for (final current in [anchor, sameAnchorAgain, filler, story, null]) {
      for (final includeStory in [false, true]) {
        final result = episodeChromeNavigation(
          episodes: list,
          currentEpisode: current,
          currentEpisodeUrl: 'anchor',
          includeFillerStory: includeStory,
        );
        final next = adjacentEpisode(
          episodes: list,
          currentEpisode: current,
          currentEpisodeUrl: 'anchor',
          offset: 1,
        );
        expect(result.next, same(next));
        expect(
          result.previous,
          same(
            adjacentEpisode(
              episodes: list,
              currentEpisode: current,
              currentEpisodeUrl: 'anchor',
              offset: -1,
            ),
          ),
        );
        expect(
          result.story,
          includeStory && (next?.isFiller ?? false)
              ? same(
                  nextStoryEpisode(
                    episodes: list,
                    currentEpisode: current,
                    currentEpisodeUrl: 'anchor',
                  ),
                )
              : isNull,
        );
      }
    }

    expect(
      episodeChromeNavigation(
        episodes: list,
        currentEpisode: anchor,
        currentEpisodeUrl: '',
        includeFillerStory: true,
      ),
      (previous: prior, next: filler, story: story),
    );
    expect(
      episodeChromeNavigation(
        episodes: list.take(6).toList(),
        currentEpisode: anchor,
        currentEpisodeUrl: '',
        includeFillerStory: true,
      ),
      (previous: prior, next: filler, story: null),
    );
  });

  test('chrome projection is empty without a valid anchor', () {
    for (final episodes in [
      null,
      <Episode>[],
      [_episode(1)],
    ]) {
      for (final url in ['', 'missing']) {
        expect(
          episodeChromeNavigation(
            episodes: episodes,
            currentEpisode: null,
            currentEpisodeUrl: url,
            includeFillerStory: true,
          ),
          (previous: null, next: null, story: null),
        );
      }
    }
  });
}

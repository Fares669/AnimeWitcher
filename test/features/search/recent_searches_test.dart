import 'dart:convert';

import 'package:animewitcher/features/search/data/recent_searches.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('recording a search', () {
    test('puts the newest first', () {
      var list = <String>[];
      list = withRecentSearch(list, 'One Piece');
      list = withRecentSearch(list, 'Mao');
      expect(list, <String>['Mao', 'One Piece']);
    });

    test('trims what it stores', () {
      expect(withRecentSearch(const <String>[], '  Mao  '), <String>['Mao']);
    });

    test('a repeat moves up instead of appearing twice', () {
      final list = withRecentSearch(
        <String>['Mao', 'One Piece', 'Bleach'],
        'One Piece',
      );
      expect(list, <String>['One Piece', 'Mao', 'Bleach']);
    });

    test('the same search in different capitals is the same search', () {
      // Two entries differing only in case read as a bug, and Arabic-keyboard
      // users switch layouts mid-title often enough for this to show up.
      final list = withRecentSearch(<String>['One Piece'], 'one piece');
      expect(list, <String>['one piece'], reason: 'kept as last typed');
      expect(list, hasLength(1));
    });

    test('an empty submit leaves the list alone', () {
      const existing = <String>['Mao'];
      expect(withRecentSearch(existing, ''), same(existing));
      expect(withRecentSearch(existing, '   '), same(existing));
    });

    test('keeps at most the cap, dropping the oldest', () {
      var list = <String>[];
      for (var i = 1; i <= recentSearchesMax + 3; i++) {
        list = withRecentSearch(list, 'anime $i');
      }
      expect(list, hasLength(recentSearchesMax));
      expect(list.first, 'anime ${recentSearchesMax + 3}');
      expect(list.contains('anime 1'), isFalse);
      expect(list.contains('anime 2'), isFalse);
    });

    test('a repeat near the end survives a full list', () {
      var list = <String>[];
      for (var i = 1; i <= recentSearchesMax; i++) {
        list = withRecentSearch(list, 'anime $i');
      }
      // 'anime 1' is the oldest; searching it again should save it, not
      // push it out.
      list = withRecentSearch(list, 'anime 1');
      expect(list.first, 'anime 1');
      expect(list, hasLength(recentSearchesMax));
    });
  });

  group('removing', () {
    test('takes out the one asked for, case aside', () {
      expect(
        withoutRecentSearch(<String>['Mao', 'One Piece'], 'one piece'),
        <String>['Mao'],
      );
    });

    test('an unknown entry changes nothing', () {
      const existing = <String>['Mao'];
      expect(withoutRecentSearch(existing, 'Bleach'), <String>['Mao']);
      expect(withoutRecentSearch(existing, '  '), same(existing));
    });
  });

  group('reading what was stored', () {
    test('round-trips', () {
      final list = withRecentSearch(
        withRecentSearch(const <String>[], 'Mao'),
        'One Piece',
      );
      expect(parseRecentSearches(jsonEncode(list)), list);
    });

    test('nothing stored is an empty list, not a crash', () {
      expect(parseRecentSearches(null), isEmpty);
      expect(parseRecentSearches(''), isEmpty);
      expect(parseRecentSearches('   '), isEmpty);
    });

    test('a shape it does not recognise is ignored', () {
      expect(parseRecentSearches('not json'), isEmpty);
      expect(parseRecentSearches('{"a":1}'), isEmpty);
      expect(parseRecentSearches('[1, 2, 3]'), isEmpty);
    });

    test('skips blanks and duplicates inside stored data', () {
      expect(
        parseRecentSearches('["Mao", "", "  ", "mao", "One Piece"]'),
        <String>['Mao', 'One Piece'],
      );
    });

    test('honours the cap even if more was stored', () {
      final many = <String>[for (var i = 0; i < 50; i++) 'anime $i'];
      expect(
        parseRecentSearches(jsonEncode(many)),
        hasLength(recentSearchesMax),
      );
    });
  });
}

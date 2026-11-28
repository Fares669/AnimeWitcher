import 'dart:async';
import 'dart:collection';

import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/features/comments/presentation/comment_pager.dart';
import 'package:flutter_test/flutter_test.dart';

AnimeWitcherComment _row(String id, [String? text]) => AnimeWitcherComment(
  id: id,
  path: 'offline/comments/$id',
  text: text ?? id,
  userId: 'u',
  userName: 'قارئ',
  likes: 0,
  replies: 0,
  spoiler: false,
);

AnimeWitcherCommentPage _page(
  List<AnimeWitcherComment> items,
  String id, {
  bool more = true,
}) => AnimeWitcherCommentPage(
  items: items,
  cursor: FirestoreDocument(id: id, path: 'offline/$id', fields: const {}),
  hasMore: more,
);

List<String> _texts(CommentPager pager) =>
    pager.items.map((item) => item.text).toList();

final class _BrokenPage extends ListBase<AnimeWitcherComment> {
  final first = _row('b');

  @override
  int get length => 2;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  AnimeWitcherComment operator [](int index) {
    if (index == 0) return first;
    throw StateError('broken local page iterator');
  }

  @override
  void operator []=(int index, AnimeWitcherComment value) =>
      throw UnsupportedError('read only');
}

void main() {
  test(
    'owned index tracks edits/deletes but keeps first-page duplicate order',
    () async {
      final pager = CommentPager();
      final callerPage = <AnimeWitcherComment>[
        _row('a'),
        _row('a', 'a duplicate'),
        _row('b'),
      ];
      expect(
        await pager.loadInitial((cursor) async {
          expect(cursor, isNull);
          return _page(callerPage, 'first');
        }),
        isTrue,
      );
      final owned = pager.items;
      callerPage.clear();
      expect(_texts(pager), ['a', 'a duplicate', 'b']);
      expect(() => owned.clear(), throwsUnsupportedError);
      expect(
        await pager.loadMore((cursor) async {
          expect(cursor?.id, 'first');
          return _page([_row('a', 'ignored'), _row('c')], 'second');
        }),
        isTrue,
      );
      expect(identical(pager.items, owned), isTrue);
      expect(_texts(pager), ['a', 'a duplicate', 'b', 'c']);

      // An in-flight append must consult mutations completed before it returns.
      final held = Completer<AnimeWitcherCommentPage>();
      final append = pager.loadMore((_) => held.future);
      pager.replaceAt(1, _row('a', 'a edited'));
      pager.removePath(_row('a').path);
      held.complete(_page([_row('a', 'a returned'), _row('b')], 'third'));
      expect(await append, isTrue);
      expect(_texts(pager), ['b', 'c', 'a returned']);

      // Changing a row's path invalidates the lookup rather than leaving a
      // stale key or accidentally dropping a still-present duplicate.
      pager.replaceAt(0, _row('d', 'd replacement'));
      expect(
        await pager.loadMore((cursor) async {
          expect(cursor?.id, 'third');
          return _page(
            [_row('d', 'ignore'), _row('b', 'b returned')],
            'last',
            more: false,
          );
        }),
        isTrue,
      );
      expect(identical(pager.items, owned), isTrue);
      expect(_texts(pager), ['d replacement', 'c', 'a returned', 'b returned']);
      expect(pager.hasMore, isFalse);
      expect(
        await pager.loadMore((_) async => throw StateError('terminal')),
        isFalse,
      );
    },
  );

  test(
    'refresh generation discards a held old append and uses new paths',
    () async {
      final pager = CommentPager();
      await pager.loadInitial((_) async => _page([_row('a')], 'old'));
      final old = Completer<AnimeWitcherCommentPage>();
      final stale = pager.loadMore((_) => old.future);
      await pager.loadInitial((_) async => _page([_row('b')], 'fresh'));
      old.complete(_page([_row('a'), _row('stale')], 'must-not-be-used'));
      expect(await stale, isFalse);
      expect(pager.loadingMore, isFalse);
      expect(_texts(pager), ['b']);
      await pager.loadMore((cursor) async {
        expect(cursor?.id, 'fresh');
        return _page([_row('b', 'skip'), _row('a')], 'new');
      });
      expect(_texts(pager), ['b', 'a']);
    },
  );

  test(
    'iterator failure leaves cursor and committed dedupe state intact',
    () async {
      final pager = CommentPager();
      await pager.loadInitial((_) async => _page([_row('a')], 'first'));
      Object? error;
      expect(
        await pager.loadMore(
          (_) async => _page(_BrokenPage(), 'bad'),
          onError: (value) => error = value,
        ),
        isTrue,
      );
      expect(error, isA<StateError>());
      expect(pager.loadError, error);
      expect(pager.cursor?.id, 'first');
      expect(pager.loadingMore, isFalse);
      expect(_texts(pager), ['a']);
      expect(
        await pager.loadMore((cursor) async {
          expect(cursor?.id, 'first');
          return _page([_row('b'), _row('b', 'repeat')], 'retry');
        }),
        isTrue,
      );
      expect(_texts(pager), ['a', 'b']);
    },
  );
}

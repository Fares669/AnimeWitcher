import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/animewitcher_comment_models.dart';
import '../../../core/account/firestore_rest_client.dart';
import 'comment_pager.dart';
import 'comment_screen_messages.dart';

/// Paging UI shared by Comments and Replies, which each keep one stable pager.
/// The route still owns its fetch, error wording, and controller lifecycle.
abstract class CommentThreadState<T extends ConsumerStatefulWidget>
    extends ConsumerState<T>
    with CommentScreenMessages<T> {
  CommentThreadState(this._sort, this._pageErrorText);

  final String Function(Object) _pageErrorText;
  final CommentPager pager = CommentPager();
  late final ScrollController threadScroll;
  AnimeWitcherCommentSort _sort;

  AnimeWitcherCommentSort get threadSort => _sort;
  Future<AnimeWitcherCommentPage> fetchThreadPage(FirestoreDocument? cursor);

  void initThreadScroll() {
    threadScroll = ScrollController()..addListener(_onScroll);
  }

  void disposeThreadScroll() {
    threadScroll
      ..removeListener(_onScroll)
      ..dispose();
  }

  void loadThreadAfterFirstFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reloadThread();
    });
  }

  void _onScroll() {
    if (pager.shouldLoadMore(threadScroll)) _loadMore();
  }

  Future<void> reloadThread() async {
    if (!mounted) return;
    final future = pager.loadInitial(fetchThreadPage);
    setState(() {});
    if (await future && mounted) setState(() {});
  }

  Future<void> _loadMore() async {
    if (pager.loadingInitial || pager.loadingMore || !pager.hasMore) return;
    final future = pager.loadMore(
      fetchThreadPage,
      onError: (error) {
        if (mounted) showCommentMessage(_pageErrorText(error), isError: true);
      },
    );
    setState(() {});
    if (await future && mounted) setState(() {});
  }

  Future<void> selectThreadSort(String value) async {
    final selected = AnimeWitcherCommentSort.fromNameOr(value, _sort);
    if (selected == _sort || !mounted) return;
    setState(() => _sort = selected);
    if (threadScroll.hasClients) {
      threadScroll.jumpTo(0);
    }
    await reloadThread();
  }
}

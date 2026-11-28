// Shared by readers adapted from Mangayomi (Apache-2.0).
// See docs/third_party/MANGAYOMI_READER_NOTICE.md.
import 'package:flutter/widgets.dart';

import 'manga_chapter_transition_page.dart';

/// Chapter-end navigation shared by the continuous and Webtoon readers.
mixin MangaReaderTrailingAdvance<T extends StatefulWidget> on State<T> {
  @protected
  ScrollController get trailingScrollController;

  @protected
  bool get hasTrailingChapterPage;

  @protected
  VoidCallback? get trailingAdvanceCallback;

  bool _trailingAdvanceRequested = false;

  void _requestTrailingAdvance() {
    final callback = trailingAdvanceCallback;
    if (_trailingAdvanceRequested ||
        !hasTrailingChapterPage ||
        callback == null) {
      return;
    }
    _trailingAdvanceRequested = true;
    callback();
  }

  bool _handleOverscroll(OverscrollNotification notification) {
    if (!mangaReaderShouldAdvancePastTransition(
      extentAfter: notification.metrics.extentAfter,
      overscroll: notification.overscroll,
    )) {
      return false;
    }
    _requestTrailingAdvance();
    return true;
  }

  @protected
  bool handleTrailingScrollNotification(ScrollNotification notification) {
    if (notification is OverscrollNotification) {
      return _handleOverscroll(notification);
    }
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      checkTrailingProximity(notification.metrics);
    }
    return false;
  }

  /// The trailing divider is the end of the chapter: once less than a
  /// quarter of the viewport is left below the fold, the reader moves on
  /// by itself — no tap, no extra fling, and no dependence on a visibility
  /// report for the divider. Scrolling clearly away from the end re-arms
  /// the advance, so one that was dropped (a chapter navigation already
  /// in flight, a chapter list not ready yet) is retried on the next
  /// approach instead of never.
  @protected
  void checkTrailingProximity(ScrollMetrics metrics) {
    if (!hasTrailingChapterPage || trailingAdvanceCallback == null) {
      return;
    }
    final threshold = metrics.viewportDimension * 0.25;
    if (metrics.extentAfter <= threshold) {
      _requestTrailingAdvance();
    } else if (metrics.extentAfter > threshold * 2) {
      _trailingAdvanceRequested = false;
    }
  }

  @protected
  void checkTrailingProximitySoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = trailingScrollController;
      if (!controller.hasClients) return;
      checkTrailingProximity(controller.position);
    });
  }
}

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Whether a details/episodes horizontal swipe should be ignored because it
/// started over the similar/related/characters pager.
///
/// The details tab stays mounted under [AutomaticKeepAliveClientMixin], so
/// extra-tabs still has a [RenderBox] after switching to Episodes. Treating
/// that off-stage box as live would swallow the swipe back to Details.
bool ignoreDetailsEpisodesSwipe({
  required int selectedDetailsTab,
  required bool pointerInExtraTabsBounds,
}) {
  return selectedDetailsTab == 0 && pointerInExtraTabsBounds;
}

class DetailsEpisodesSwipeGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  DetailsEpisodesSwipeGestureRecognizer({required this.shouldIgnore});

  final bool Function(Offset globalPosition) shouldIgnore;

  @override
  void addPointer(PointerDownEvent event) {
    if (shouldIgnore(event.position)) return;
    super.addPointer(event);
  }
}

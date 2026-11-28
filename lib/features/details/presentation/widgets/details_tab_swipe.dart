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

/// Switches the heavy desktop details pages without putting both of them in a
/// horizontally animating [PageView]. Windows renders the hero and episode
/// grid through separate scrolling/compositing trees, so mounting only the
/// active tree keeps tab changes responsive while the outer gesture detector
/// handles desktop swipes.
class DetailsDesktopTabSwitcher extends StatelessWidget {
  const DetailsDesktopTabSwitcher({
    super.key,
    required this.selectedIndex,
    required this.transition,
    required this.slideFrom,
    required this.detailsBuilder,
    required this.episodesBuilder,
  });

  final int selectedIndex;
  final Animation<double> transition;
  final Offset slideFrom;
  final WidgetBuilder detailsBuilder;
  final WidgetBuilder episodesBuilder;

  @override
  Widget build(BuildContext context) {
    assert(selectedIndex == 0 || selectedIndex == 1);
    final activeChild = selectedIndex == 0
        ? detailsBuilder(context)
        : episodesBuilder(context);

    return FadeTransition(
      opacity: transition,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: slideFrom,
          end: Offset.zero,
        ).animate(transition),
        child: KeyedSubtree(
          key: ValueKey<int>(selectedIndex),
          child: activeChild,
        ),
      ),
    );
  }
}

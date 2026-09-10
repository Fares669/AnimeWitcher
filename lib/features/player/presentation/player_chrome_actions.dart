/// Optional buttons on the player bottom-right cluster, in visual LTR order.
///
/// Touch layout right-aligns this list (`PlayerBottomBar` reverse scroll),
/// so index 0 sits immediately left of the following icon. PiP is placed
/// just before rotate — left of the rotation button in the screenshot.
///
/// Anime4K sits next to resize because both are about how the picture is
/// drawn rather than what is playing.
enum PlayerChromeAction {
  playbackSpeed,
  pip,
  rotate,
  episodes,
  anime4k,
  resize,
  desktopFullscreen,
}

class PlayerChromeActions {
  const PlayerChromeActions._();

  static List<PlayerChromeAction> visible({
    required bool showPlaybackSpeed,
    required bool supportsPlaybackSpeed,
    required bool showPip,
    required bool pipSupported,
    required bool showRotate,
    required bool canRotate,
    required bool showEpisodes,
    required bool hasEpisodePicker,
    required bool showResize,
    required bool isDesktop,
    required bool anime4kOn,
    required bool anime4kSupported,
  }) {
    return [
      if (supportsPlaybackSpeed && showPlaybackSpeed)
        PlayerChromeAction.playbackSpeed,
      if (showPip && pipSupported) PlayerChromeAction.pip,
      if (showRotate && canRotate) PlayerChromeAction.rotate,
      if (hasEpisodePicker && showEpisodes) PlayerChromeAction.episodes,
      // Only once a pipeline is chosen. A button that opens a panel saying
      // "off" is a button that has nothing to do, and this row is already
      // full on a phone. It also goes when the backend cannot run shaders,
      // rather than offering a change that would not reach the picture.
      if (anime4kOn && anime4kSupported) PlayerChromeAction.anime4k,
      if (showResize) PlayerChromeAction.resize,
      if (isDesktop) PlayerChromeAction.desktopFullscreen,
    ];
  }
}

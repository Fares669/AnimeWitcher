import '../../core/domain/entity/multimedia_item.dart';
import '../../core/storage/history_repository.dart';
import '../../l10n/generated/app_localizations.dart';

typedef EpisodeWatchPresentation = ({
  bool isWatched,
  double progress,
  String? statusBadge,
});

const noEpisodeWatch = (isWatched: false, progress: 0.0, statusBadge: null);

extension EpisodeWatchProjection on Episode {
  ({double progress, int duration}) historyProgress(
    HistoryRepository repository,
    MultimediaItem item,
  ) {
    final position = repository.getEpisodePosition(
      url,
      mainUrl: item.url,
      season: season,
      episode: episode,
    );
    final duration = repository.getEpisodeDuration(
      url,
      mainUrl: item.url,
      season: season,
      episode: episode,
    );
    return (
      progress: duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0,
      duration: duration,
    );
  }

  /// Projects an already-resolved authority into the shared badge and meter.
  EpisodeWatchPresentation watchPresentation(
    AppLocalizations l10n,
    HistoryItem? historyItem,
    double progress, {
    required bool isWatched,
    required bool? explicitWatchState,
  }) {
    String? badge;
    if (isWatched) {
      badge = l10n.watched;
    } else if (progress > 0.02) {
      badge = l10n.watching;
    } else if (historyItem != null &&
        explicitWatchState != false &&
        season == (historyItem.season ?? 1) &&
        episode == (historyItem.episode ?? 1)) {
      badge = l10n.lastWatched;
    }
    return (
      isWatched: isWatched,
      progress: isWatched ? 1.0 : progress,
      statusBadge: badge?.toUpperCase(),
    );
  }
}

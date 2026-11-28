import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_download_index.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _show(String url, String? provider) =>
    MultimediaItem(title: 'Show', url: url, posterUrl: '', provider: provider);

Episode _episode(String url) => Episode(name: 'Episode', url: url);

DownloadItem _download({
  required String id,
  required MultimediaItem show,
  required TaskStatus status,
  required String tracking,
  String? episode,
  DownloadMediaKind kind = DownloadMediaKind.videoEpisode,
}) => DownloadItem(
  task: DownloadTask(
    taskId: id,
    url: 'https://example.test/video.mp4',
    filename: 'video.mp4',
  ),
  item: show,
  episode: episode == null ? null : _episode(episode),
  status: status,
  mediaKind: kind,
  progress: 0,
  trackingUrl: tracking,
  timestamp: 0,
);

DownloadItem? _oldActiveMatcher(
  Iterable<DownloadItem> downloads,
  MultimediaItem parent,
  String episode,
) => downloads
    .where(
      (item) =>
          (item.trackingUrl.trim() == episode ||
              (item.episode?.url.trim() ?? '') == episode) &&
          sameDownloadProvider(item.item, parent) &&
          item.item.url.trim() == parent.url.trim() &&
          item.status != TaskStatus.complete &&
          item.status != TaskStatus.canceled,
    )
    .firstOrNull;

void main() {
  test(
    'first current row, provider/media/series scope and aliases match baseline',
    () {
      final native = _show('  title ', 'AnimeWitcher');
      final local = _show('title', 'Local');
      final foreign = _show('title', 'other');
      final canceled = _download(
        id: 'canceled',
        show: local,
        status: TaskStatus.canceled,
        tracking: 'tracking',
        episode: 'metadata',
      );
      final foreignRow = _download(
        id: 'foreign',
        show: foreign,
        status: TaskStatus.complete,
        tracking: 'tracking',
      );
      final otherSeries = _download(
        id: 'other',
        show: _show('different', 'Local'),
        status: TaskStatus.complete,
        tracking: 'metadata',
      );
      final manga = _download(
        id: 'manga',
        show: local,
        status: TaskStatus.complete,
        tracking: 'tracking',
        episode: 'metadata',
        kind: DownloadMediaKind.mangaChapter,
      );
      final complete = _download(
        id: 'complete',
        show: local,
        status: TaskStatus.complete,
        tracking: ' tracking ',
        episode: ' metadata ',
      );
      final nextComplete = _download(
        id: 'nextComplete',
        show: local,
        status: TaskStatus.complete,
        tracking: 'tracking',
      );
      final active = _download(
        id: 'active',
        show: local,
        status: TaskStatus.failed,
        tracking: 'active',
        episode: 'metadata',
      );
      final activeWithEmptyMetadata = _download(
        id: 'noMetadata',
        show: local,
        status: TaskStatus.paused,
        tracking: 'odd-legacy',
      );
      final rows = [
        canceled,
        foreignRow,
        otherSeries,
        manga,
        complete,
        nextComplete,
        active,
        activeWithEmptyMetadata,
      ];

      for (final parent in [native, foreign, _show('', 'Remote')]) {
        final result = EpisodeDownloadIndex(rows, episodeDownloadScope(parent));
        for (final url in [
          'tracking',
          'metadata',
          'active',
          'odd-legacy',
          '',
          'missing',
        ]) {
          final before = completedEpisodeDownload(rows, parent, _episode(url));
          final matches = result.forEpisode(url);
          expect(
            matches.completed,
            same(before),
            reason: '${parent.provider}: $url',
          );
          expect(matches.active, same(_oldActiveMatcher(rows, parent, url)));
          expect(result.completedEpisodes.contains(url), before != null);
        }
      }
    },
  );

  test(
    'filter membership ignores progress but notices completion and removal',
    () {
      final show = _show('title', 'Local');
      final scope = episodeDownloadScope(show);
      final complete = _download(
        id: 'complete',
        show: show,
        status: TaskStatus.complete,
        tracking: 'x',
      );
      final active = _download(
        id: 'other',
        show: show,
        status: TaskStatus.running,
        tracking: 'y',
      );
      EpisodeDownloadMembership membership(List<DownloadItem> rows) =>
          EpisodeDownloadIndex(rows, scope).completedEpisodes;
      expect(membership([complete, active]), membership([complete]));
      expect(membership([complete, active]), isNot(membership([active])));
    },
  );
}

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/services/download_v2/download_v2_identity.dart';
import '../../../../core/services/download_v2/download_v2_models.dart';
import '../../../library/presentation/downloads_provider.dart';

typedef EpisodeDownloadScope = (String? providerScope, String seriesUrl);

EpisodeDownloadScope episodeDownloadScope(MultimediaItem item) =>
    (downloadProviderScopeV2(item.provider), item.url.trim());

/// Only the open Details route needs this projection. Traverse the
/// authorized Downloads snapshot once per show, not twice per episode card.
final episodeDownloadsForDetailsProvider = Provider.autoDispose
    .family<EpisodeDownloadIndex, EpisodeDownloadScope>((ref, scope) {
      final downloads =
          ref.watch(downloadsProvider).value ?? const <DownloadItem>[];
      return EpisodeDownloadIndex(downloads, scope);
    });

class EpisodeDownloadIndex {
  EpisodeDownloadIndex(List<DownloadItem> downloads, EpisodeDownloadScope scope)
    : _completed = <String, DownloadItem>{},
      _active = <String, DownloadItem>{} {
    final (providerScope, seriesUrl) = scope;
    final scopes = <String?, String?>{};
    for (final item in downloads) {
      final completed = item.status == TaskStatus.complete;
      if (completed && item.mediaKind != DownloadMediaKind.videoEpisode) {
        continue;
      }
      if (item.status == TaskStatus.canceled ||
          ((!completed || seriesUrl.isNotEmpty) &&
              item.item.url.trim() != seriesUrl)) {
        continue;
      }
      final provider = item.item.provider;
      if (scopes.putIfAbsent(
            provider,
            () => downloadProviderScopeV2(provider),
          ) !=
          providerScope) {
        continue;
      }

      final tracking = item.trackingUrl.trim();
      final episode = item.episode?.url.trim() ?? '';
      // The old matchers selected the first row in Downloads order and
      // checked both URL aliases. A completed row needs a nonempty URL.
      final output = completed ? _completed : _active;
      if (!completed || tracking.isNotEmpty) {
        output.putIfAbsent(tracking, () => item);
      }
      if (episode != tracking && (!completed || episode.isNotEmpty)) {
        output.putIfAbsent(episode, () => item);
      }
    }
  }

  final Map<String, DownloadItem> _completed;
  final Map<String, DownloadItem> _active;

  ({DownloadItem? completed, DownloadItem? active}) forEpisode(String url) =>
      (completed: _completed[url], active: _active[url]);

  late final EpisodeDownloadMembership completedEpisodes =
      EpisodeDownloadMembership._(_completed.keys.toSet());
}

/// A filter only depends on membership, not progress, task incarnations,
/// or other row metadata. Keep only immutable URL keys, not an old map of download objects.
class EpisodeDownloadMembership {
  EpisodeDownloadMembership._(this._completed);

  final Set<String> _completed;

  bool contains(String url) => _completed.contains(url);

  @override
  bool operator ==(Object other) =>
      other is EpisodeDownloadMembership &&
      (_completed.length == other._completed.length) &&
      _completed.every(other._completed.contains);

  @override
  int get hashCode => Object.hashAllUnordered(_completed);
}

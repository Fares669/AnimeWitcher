import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/settings_repository.dart';
import '../utils/artwork_host_fallback.dart';
import '../utils/artwork_quality.dart';

class AnimeDataSourceSettings {
  final bool episodeImagesFromAniZip;

  /// Posters are requested and decoded at their largest available size.
  /// Turning this off keeps the lighter standard artwork.
  final bool highQualityPosters;

  /// Look for a poster elsewhere when the catalog's own artwork host cannot
  /// be reached. Off by default, since it only helps on networks that block
  /// that host.
  final bool artworkFallback;

  const AnimeDataSourceSettings({
    this.episodeImagesFromAniZip = true,
    this.highQualityPosters = true,
    this.artworkFallback = false,
  });

  AnimeDataSourceSettings copyWith({
    bool? episodeImagesFromAniZip,
    bool? highQualityPosters,
    bool? artworkFallback,
  }) {
    return AnimeDataSourceSettings(
      episodeImagesFromAniZip:
          episodeImagesFromAniZip ?? this.episodeImagesFromAniZip,
      highQualityPosters: highQualityPosters ?? this.highQualityPosters,
      artworkFallback: artworkFallback ?? this.artworkFallback,
    );
  }
}

final animeDataSourceSettingsProvider =
    NotifierProvider<AnimeDataSourceSettingsNotifier, AnimeDataSourceSettings>(
      AnimeDataSourceSettingsNotifier.new,
    );

class AnimeDataSourceSettingsNotifier
    extends Notifier<AnimeDataSourceSettings> {
  late final SettingsRepository _repository;

  @override
  AnimeDataSourceSettings build() {
    _repository = ref.watch(settingsRepositoryProvider);
    final highQualityPosters = _repository.isHighQualityPostersEnabled();
    applyArtworkQuality(highQualityPosters);
    final artworkFallback = _repository.isArtworkFallbackEnabled();
    applyArtworkFallbackEnabled(artworkFallback);
    return AnimeDataSourceSettings(
      episodeImagesFromAniZip: _repository.isEpisodeImagesFromAniZipEnabled(),
      highQualityPosters: highQualityPosters,
      artworkFallback: artworkFallback,
    );
  }

  Future<void> setEpisodeImagesFromAniZip(bool enabled) async {
    state = state.copyWith(episodeImagesFromAniZip: enabled);
    await _repository.setEpisodeImagesFromAniZipEnabled(enabled);
  }

  Future<void> setArtworkFallback(bool enabled) async {
    state = state.copyWith(artworkFallback: enabled);
    applyArtworkFallbackEnabled(enabled);
    await _repository.setArtworkFallbackEnabled(enabled);
    if (!enabled || !ref.mounted) return;
    // Turning this on is how someone reacts to blank posters, so answer the
    // question now rather than at the next launch.
    final unreachable = await probeMalArtworkUnreachable();
    if (!ref.mounted || unreachable == null) return;
    seedMalArtworkReachability(unreachable);
    await _repository.setMalArtworkUnreachable(unreachable);
  }

  Future<void> setHighQualityPosters(bool enabled) async {
    state = state.copyWith(highQualityPosters: enabled);
    applyArtworkQuality(enabled);
    await _repository.setHighQualityPostersEnabled(enabled);
  }
}

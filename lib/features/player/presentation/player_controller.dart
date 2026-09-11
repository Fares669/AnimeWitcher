import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:video_view/video_view.dart'
    show VideoController, SubtitleTrackConfig, VideoControllerPlaybackState;

import '../../../../core/logger/app_logger.dart';

import 'package:animewitcher/core/account/account_providers.dart';

import '../../../../core/services/download_service.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/storage/history_repository.dart';
import '../../../../core/storage/episode_watch_repository.dart';
import '../../library/presentation/history_provider.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../core/utils/app_utils.dart';
import '../../../core/utils/episode_label.dart';
import 'episode_navigation.dart';
import '../../details/presentation/stream_source_prefetch.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../core/utils/stream_response_validator.dart';
import '../../settings/presentation/player_settings_provider.dart';
import '../../../../core/services/local_proxy_service.dart';
import '../../../../core/network/http_defaults.dart';
import '../../skip/data/intro_db_service.dart';
import '../../skip/data/aniskip_service.dart';
import '../../skip/data/chapter_skip_source.dart';
import '../../skip/data/anime_id_mappings.dart';
import '../../skip/data/mal_id_resolver.dart';
import '../../skip/data/skip_segment_cache.dart';
import '../../skip/data/skip_service.dart';
import '../../../../core/storage/settings_repository.dart';
import 'playback_recovery_policy.dart';
import 'playback_resume.dart';
import '../data/anime4k.dart';
import '../data/anime4k_shader_library.dart';

enum PlaybackUiPhaseKind {
  idle,
  bootstrapping,
  fetchingSources,
  checkingSources,
  openingSource,
  switchingEngine,
  bufferingInitial,
  bufferingRuntime,
  switchingSource,
  reconnectingLive,
  loadingNextEpisode,
  error,
}

enum SourceAttemptStatus { pending, trying, failed, selected, playing }

class SourceAttemptEntry {
  final int index;
  final SourceAttemptStatus status;

  const SourceAttemptEntry({
    required this.index,
    this.status = SourceAttemptStatus.pending,
  });

  SourceAttemptEntry copyWith({SourceAttemptStatus? status}) {
    return SourceAttemptEntry(index: index, status: status ?? this.status);
  }
}

class PlaybackUiPhase {
  final PlaybackUiPhaseKind kind;
  final bool fullscreenBlocking;

  const PlaybackUiPhase({required this.kind, this.fullscreenBlocking = false});

  const PlaybackUiPhase.idle() : this(kind: PlaybackUiPhaseKind.idle);

  bool get isIdle => kind == PlaybackUiPhaseKind.idle;
}

class PlayerState {
  final String? errorMessage;
  final String playerTitle;
  final List<StreamResult> streams;
  final int currentStreamIndex;
  final StreamResult? currentStream;
  final String? activeEpisodeUrl;
  final StreamResult? previousStream;
  final List<SubtitleFile> externalSubtitles;
  final bool showNextEpisodeOverlay;
  final String? nextEpisodeTitle;
  final String? nextEpisodePosterUrl;
  final double? nextEpisodeRating;
  final int? nextEpisodeNumber;
  final int? nextEpisodeSeason;
  final int? nextEpisodeRuntime;
  final String? nextEpisodeDescription;
  final bool nextEpisodeIsFinal;
  final String? nextEpisodeServerName;
  final bool isAdaptiveBufferingActive;
  final bool showEpisodeList;

  final double playbackSpeed;
  final bool isLive;
  final double subtitleDelay;
  final String? imdbId;
  final int? tmdbId;

  /// Whether the active engine is video_view (ExoPlayer/AVPlayer) instead of media_kit.
  final bool useExoPlayer;
  final bool isSeekable;
  final PlaybackUiPhase uiPhase;
  final List<SourceAttemptEntry> sourceAttempts;
  final int sourceSessionId;

  final List<SkipSegment> skipSegments;

  const PlayerState({
    this.errorMessage,
    this.playerTitle = '',
    this.streams = const [],
    this.currentStreamIndex = 0,
    this.currentStream,
    this.activeEpisodeUrl,
    this.previousStream,
    this.externalSubtitles = const [],
    this.showNextEpisodeOverlay = false,
    this.nextEpisodeTitle,
    this.nextEpisodePosterUrl,
    this.nextEpisodeRating,
    this.nextEpisodeNumber,
    this.nextEpisodeSeason,
    this.nextEpisodeRuntime,
    this.nextEpisodeDescription,
    this.nextEpisodeIsFinal = false,
    this.nextEpisodeServerName,
    this.isAdaptiveBufferingActive = false,
    this.showEpisodeList = false,
    this.playbackSpeed = 1.0,
    this.isLive = false,
    this.isSeekable = false,
    this.subtitleDelay = 0.0,
    this.imdbId,
    this.tmdbId,
    this.useExoPlayer = false,
    this.uiPhase = const PlaybackUiPhase(
      kind: PlaybackUiPhaseKind.bootstrapping,
      fullscreenBlocking: true,
    ),
    this.sourceAttempts = const [],
    this.sourceSessionId = 0,
    this.skipSegments = const [],
  });

  bool get isLoading => const {
    PlaybackUiPhaseKind.bootstrapping,
    PlaybackUiPhaseKind.fetchingSources,
    PlaybackUiPhaseKind.checkingSources,
    PlaybackUiPhaseKind.openingSource,
    PlaybackUiPhaseKind.bufferingInitial,
  }.contains(uiPhase.kind);

  bool get isBuffering => uiPhase.kind == PlaybackUiPhaseKind.bufferingRuntime;

  bool get canSeek => !useExoPlayer || isSeekable;
  bool get supportsPlaybackSpeed => !isLive;
  double get maxPlaybackSpeed => useExoPlayer ? 2.0 : 3.0;
  bool get supportsVolumeBoost => !useExoPlayer;
  bool get supportsSubtitleDelay => !useExoPlayer;
  bool get supportsSubtitleStyling => !useExoPlayer;
  bool get supportsExternalSubtitleLoading =>
      !useExoPlayer || Platform.isAndroid;

  PlayerState copyWith({
    String? errorMessage,
    String? playerTitle,
    List<StreamResult>? streams,
    int? currentStreamIndex,
    StreamResult? currentStream,
    String? activeEpisodeUrl,
    StreamResult? previousStream,
    List<SubtitleFile>? externalSubtitles,
    bool? showNextEpisodeOverlay,
    String? nextEpisodeTitle,
    String? nextEpisodePosterUrl,
    double? nextEpisodeRating,
    int? nextEpisodeNumber,
    int? nextEpisodeSeason,
    int? nextEpisodeRuntime,
    String? nextEpisodeDescription,
    bool? nextEpisodeIsFinal,
    String? nextEpisodeServerName,
    bool? isAdaptiveBufferingActive,
    bool? showEpisodeList,
    double? playbackSpeed,
    bool? isLive,
    bool? isSeekable,
    double? subtitleDelay,
    String? imdbId,
    int? tmdbId,
    bool? useExoPlayer,
    PlaybackUiPhase? uiPhase,
    List<SourceAttemptEntry>? sourceAttempts,
    int? sourceSessionId,
    List<SkipSegment>? skipSegments,
  }) {
    return PlayerState(
      errorMessage: errorMessage ?? this.errorMessage,
      playerTitle: playerTitle ?? this.playerTitle,
      streams: streams ?? this.streams,
      currentStreamIndex: currentStreamIndex ?? this.currentStreamIndex,
      currentStream: currentStream ?? this.currentStream,
      activeEpisodeUrl: activeEpisodeUrl ?? this.activeEpisodeUrl,
      previousStream: previousStream ?? this.previousStream,
      externalSubtitles: externalSubtitles ?? this.externalSubtitles,
      showNextEpisodeOverlay:
          showNextEpisodeOverlay ?? this.showNextEpisodeOverlay,
      nextEpisodeTitle: nextEpisodeTitle ?? this.nextEpisodeTitle,
      nextEpisodePosterUrl: nextEpisodePosterUrl ?? this.nextEpisodePosterUrl,
      nextEpisodeRating: nextEpisodeRating ?? this.nextEpisodeRating,
      nextEpisodeNumber: nextEpisodeNumber ?? this.nextEpisodeNumber,
      nextEpisodeSeason: nextEpisodeSeason ?? this.nextEpisodeSeason,
      nextEpisodeRuntime: nextEpisodeRuntime ?? this.nextEpisodeRuntime,
      nextEpisodeDescription:
          nextEpisodeDescription ?? this.nextEpisodeDescription,
      nextEpisodeIsFinal: nextEpisodeIsFinal ?? this.nextEpisodeIsFinal,
      nextEpisodeServerName:
          nextEpisodeServerName ?? this.nextEpisodeServerName,
      isAdaptiveBufferingActive:
          isAdaptiveBufferingActive ?? this.isAdaptiveBufferingActive,
      showEpisodeList: showEpisodeList ?? this.showEpisodeList,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      isLive: isLive ?? this.isLive,
      isSeekable: isSeekable ?? this.isSeekable,
      subtitleDelay: subtitleDelay ?? this.subtitleDelay,
      imdbId: imdbId ?? this.imdbId,
      tmdbId: tmdbId ?? this.tmdbId,
      useExoPlayer: useExoPlayer ?? this.useExoPlayer,
      uiPhase: uiPhase ?? this.uiPhase,
      sourceAttempts: sourceAttempts ?? this.sourceAttempts,
      sourceSessionId: sourceSessionId ?? this.sourceSessionId,
      skipSegments: skipSegments ?? this.skipSegments,
    );
  }
}

class PlayerController extends Notifier<PlayerState> {
  late Player _player;
  VideoController? _videoViewController;
  late MultimediaItem _item;
  late String _videoUrl;
  String? _resolvedPlayUrl;
  bool _isInPip = false;
  late String _progressUrl;
  Episode? _episode;
  bool _isInitialized = false;
  bool _isDisposed = false;
  int _sourceSessionSerial = 0;

  bool _hasMarkedWatched = false;
  bool _hasRefreshedCloudProgress = false;

  Player get player => _player;
  VideoController? get videoViewController => _videoViewController;
  bool get isDisposed => _isDisposed;
  bool get hasConfirmedPlaybackFrame => _hasConfirmedPlaybackFrame;
  bool get isInPip => _isInPip;
  String? get resolvedPlayUrl => _resolvedPlayUrl;
  Duration get currentPosition => _currentPosition;
  Map<String, String>? get currentPlaybackHeaders {
    final stream = state.currentStream;
    if (stream == null) return null;
    return _buildPlaybackHeaders(stream);
  }

  void setInPip(bool value) {
    _isInPip = value;
  }

  PlayerState get currentState => state;
  List<SubtitleFile> get userAddedExternalSubtitles =>
      _userAddedExternalSubtitles;

  String? _episodeArtwork(Episode? episode) {
    return AppImageFallbacks.episode(
      episodeUrl: episode?.posterUrl,
      bannerUrl: _item.bannerUrl,
      posterUrl: _item.posterUrl,
      label: _item.title,
    );
  }

  Set<String>? pendingVideoViewSubtitleIdsBeforeReload;
  bool selectNewestVideoViewSubtitleAfterReload = false;

  void updateState(PlayerState Function(PlayerState s) update) {
    state = update(state);
  }

  String _playerText({required String english, required String arabic}) {
    return arabic;
  }

  bool _isDashStreamUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mpd') ||
        lower.contains('manifest.mpd') ||
        lower.contains('/dash/') ||
        lower.contains('format=mpd') ||
        lower.contains('type=mpd');
  }

  bool _streamRequiresNativeDrm(StreamResult stream) {
    return stream.drmKey != null ||
        stream.drmKid != null ||
        stream.licenseUrl != null;
  }

  bool _detectResolvedLiveState(String url) {
    return _item.contentType == MultimediaContentType.livestream ||
        _isLiveStream(url);
  }

  bool _canUseVideoViewForStream(
    String playUrl,
    StreamResult stream, {
    required bool isLive,
  }) {
    if (_videoViewController == null || Platform.isLinux || !isLive) {
      return false;
    }

    if ((Platform.isMacOS || Platform.isIOS || Platform.isWindows) &&
        (_isDashStreamUrl(playUrl) || _isDashStreamUrl(stream.url))) {
      return false;
    }

    if (!Platform.isAndroid && _streamRequiresNativeDrm(stream)) {
      return false;
    }

    return true;
  }

  Map<String, String> _buildPlaybackHeaders(StreamResult stream) {
    final headers = <String, String>{...?stream.headers};
    final hasUserAgent = headers.keys.any(
      (k) => k.toLowerCase() == 'user-agent',
    );
    if (!hasUserAgent) {
      headers['User-Agent'] = kDefaultBrowserUserAgent;
    }
    return headers;
  }

  bool get _videoViewSupportsMergedExternalSubtitles => Platform.isAndroid;

  Duration _lastSavedPosition = Duration.zero;
  static const double _saveThresholdPercent = 0.05;
  int _lastKnownPlaybackPositionMs = 0;
  int _lastKnownPlaybackDurationMs = 0;

  StreamSubscription<dynamic>? _errorSub;
  StreamSubscription<dynamic>? _playingSub;
  StreamSubscription<dynamic>? _positionSub;
  StreamSubscription<dynamic>? _durationSub;
  StreamSubscription<dynamic>? _bufferingSub;
  StreamSubscription<dynamic>? _completedSub;
  StreamSubscription<dynamic>? _rateSub;
  StreamSubscription<dynamic>? _logSub;
  StreamSubscription<dynamic>? _trackSub;

  Duration? _lastPosition;
  DateTime? _lastPositionUpdateTime;
  bool _isRecoveringFromStall = false;
  Timer? _stallRecoveryGuardTimer;
  final List<DateTime> _bufferDepletionTimes = [];
  Timer? _bufferWatchdogTimer;
  DateTime? _bufferingSince;
  Duration? _bufferingStartPosition;
  int _bufferRecoveryStage = 0;
  Timer? _stallTimer;
  Timer? _bufferingHideTimer;

  void _beginStallRecovery({Future<void>? perform}) {
    _isRecoveringFromStall = true;
    _stallRecoveryGuardTimer?.cancel();
    _stallRecoveryGuardTimer = Timer(const Duration(seconds: 10), () {
      _isRecoveringFromStall = false;
    });
    if (perform != null) {
      perform.whenComplete(() {
        _stallRecoveryGuardTimer?.cancel();
        _stallRecoveryGuardTimer = null;
        _isRecoveringFromStall = false;
      });
    }
  }

  int? _pendingResumeSeekPosition;
  bool _isApplyingPendingResumeSeek = false;
  double _lastNonZeroVolumeLevel = 1.0;
  int? _resolvedMalId;
  final List<SubtitleFile> _userAddedExternalSubtitles = [];
  bool _hasConfirmedPlaybackFrame = false;
  bool _forceSoftwareDecode = false;
  bool _suppressNextEpisodeDetection = false;
  bool _isNextEpisodeOverlayForced = false;
  bool _userDismissedOverlay = false;
  bool _manualSelectionPending = false;
  final Set<String> _failedAudioTrackIds = {};
  String? _lastKnownAudioTrackId;
  DateTime? _audioFailoverLastTime;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _isAppBackgrounded = false;
  int _midPlaybackRetryCount = 0;
  bool _isReconnectingCurrentStream = false;
  Timer? _midPlaybackRetryTimer;
  DateTime? _pausedAt;

  void _resetMidPlaybackReconnect() {
    _midPlaybackRetryTimer?.cancel();
    _midPlaybackRetryTimer = null;
    _isReconnectingCurrentStream = false;
    _midPlaybackRetryCount = 0;
  }

  void _resetBufferWatchdog() {
    _bufferingSince = null;
    _bufferingStartPosition = null;
    _bufferRecoveryStage = 0;
    _bufferWatchdogTimer?.cancel();
    _bufferWatchdogTimer = null;
  }

  void setAppBackgrounded(bool backgrounded) {
    _isAppBackgrounded = backgrounded;
    if (kDebugMode) {
      debugPrint('[Player] App backgrounded state: $backgrounded');
    }
    if (!backgrounded &&
        _hasConfirmedPlaybackFrame &&
        state.uiPhase.kind == PlaybackUiPhaseKind.bufferingRuntime) {
      _requestMidPlaybackReconnect(preferImmediate: true);
    }
  }

  PlaybackUiPhase _composeUiPhase({
    required PlaybackUiPhaseKind kind,
    bool? fullscreenBlocking,
  }) {
    final effectiveFullscreenBlocking = kind == PlaybackUiPhaseKind.error
        ? true
        : _hasConfirmedPlaybackFrame
        ? false
        : (fullscreenBlocking ?? true);
    return PlaybackUiPhase(
      kind: kind,
      fullscreenBlocking: effectiveFullscreenBlocking,
    );
  }

  void _setUiPhase(PlaybackUiPhase phase) {
    state = state.copyWith(uiPhase: phase);
  }

  void _setIdlePhase() {
    if (!state.uiPhase.isIdle) {
      state = state.copyWith(uiPhase: const PlaybackUiPhase.idle());
    }
  }

  void _enterStartupPhase({required PlaybackUiPhaseKind kind}) {
    _setUiPhase(_composeUiPhase(kind: kind, fullscreenBlocking: true));
  }

  void _enterRuntimePhase({required PlaybackUiPhaseKind kind}) {
    _setUiPhase(_composeUiPhase(kind: kind, fullscreenBlocking: false));
  }

  void _enterAllSourcesFailedPhase() {
    _setUiPhase(
      _composeUiPhase(
        kind: PlaybackUiPhaseKind.error,
        fullscreenBlocking: true,
      ),
    );
  }

  int _beginSourceSession({bool resetAttempts = false}) {
    final nextSessionId = ++_sourceSessionSerial;
    _userDismissedOverlay = false;
    state = state.copyWith(
      sourceSessionId: nextSessionId,
      sourceAttempts: resetAttempts ? const [] : state.sourceAttempts,
    );
    return nextSessionId;
  }

  bool _isCurrentSourceSession(int sessionId) =>
      !_isDisposed && _sourceSessionSerial == sessionId;

  void _setSourceAttemptsFromStreams(
    List<StreamResult> streams, {
    int? activeIndex,
    SourceAttemptStatus? activeStatus,
  }) {
    final attempts = <SourceAttemptEntry>[
      for (int i = 0; i < streams.length; i++)
        SourceAttemptEntry(
          index: i,
          status: i == activeIndex
              ? (activeStatus ?? SourceAttemptStatus.pending)
              : SourceAttemptStatus.pending,
        ),
    ];
    state = state.copyWith(sourceAttempts: attempts);
  }

  void _markSourceAttempt(int index, SourceAttemptStatus status) {
    if (index < 0 || index >= state.sourceAttempts.length) return;
    final updated = [
      for (final entry in state.sourceAttempts)
        if (entry.index == index) entry.copyWith(status: status) else entry,
    ];
    state = state.copyWith(sourceAttempts: updated);
  }

  void _confirmPlaybackStarted() {
    _hasConfirmedPlaybackFrame = true;
    _manualSelectionPending = false;
    _markSourceAttempt(state.currentStreamIndex, SourceAttemptStatus.playing);
    state = state.copyWith(uiPhase: const PlaybackUiPhase.idle());
  }

  void _maybeConfirmPlaybackStarted(int positionMs) {
    if (_hasConfirmedPlaybackFrame) return;
    if (!PlaybackResume.canRevealVideo(
      pendingResumeMs: _pendingResumeSeekPosition,
      applyingResume: _isApplyingPendingResumeSeek,
      currentMs: positionMs,
    )) {
      return;
    }
    _confirmPlaybackStarted();
  }

  @override
  PlayerState build() {
    ref.keepAlive();
    ref.onDispose(() {
      _isDisposed = true;
      ++_sourceSessionSerial;
      _stallTimer?.cancel();
      _bufferWatchdogTimer?.cancel();
      _bufferingHideTimer?.cancel();
      _midPlaybackRetryTimer?.cancel();
      _errorSub?.cancel();
      _playingSub?.cancel();
      _positionSub?.cancel();
      _durationSub?.cancel();
      _bufferingSub?.cancel();
      _completedSub?.cancel();
      _rateSub?.cancel();
      _logSub?.cancel();
      _trackSub?.cancel();
      _connectivitySub?.cancel();
    });
    return const PlayerState();
  }

  bool get isSeries =>
      _isInitialized &&
      (_item.contentType == MultimediaContentType.series ||
          _item.contentType == MultimediaContentType.anime);

  bool get hasEpisodePicker =>
      isSeries || (_isInitialized && (_item.episodes?.length ?? 0) > 1);
  MultimediaItem? get multimediaItem => _isInitialized ? _item : null;
  String? get currentEpisodeUrl => _episode?.url ?? _videoUrl;
  Episode? get currentEpisode => _episode ?? _resolveCurrentEpisode();

  Episode? get nextEpisode => _adjacentEpisode(1);
  Episode? get previousEpisode => _adjacentEpisode(-1);

  Episode? get nextStoryEpisodeOrNull {
    if (!isSeries) return null;
    return nextStoryEpisode(
      episodes: _item.episodes,
      currentEpisode: currentEpisode,
      currentEpisodeUrl: _videoUrl,
    );
  }

  Episode? _adjacentEpisode(int offset) {
    if (!isSeries) return null;
    return adjacentEpisode(
      episodes: _item.episodes,
      currentEpisode: currentEpisode,
      currentEpisodeUrl: _videoUrl,
      offset: offset,
    );
  }

  String _titleWithEpisode(Episode _) => _item.title;

  Future<void> init({
    required Player player,
    required MultimediaItem item,
    required String videoUrl,
    String? progressUrl,
    Episode? episode,
    StreamResult? selectedSource,
    VideoController? videoViewController,
  }) async {
    _isDisposed = false;
    state = PlayerState(sourceSessionId: ++_sourceSessionSerial);
    unawaited(_logSub?.cancel());
    _logSub = null;
    _hasConfirmedPlaybackFrame = false;
    _manualSelectionPending = false;
    _revertMessage = null;
    _forceSoftwareDecode = false;
    _isAppBackgrounded = false;
    _midPlaybackRetryCount = 0;
    _isReconnectingCurrentStream = false;
    _midPlaybackRetryTimer?.cancel();
    _midPlaybackRetryTimer = null;
    _pausedAt = null;
    _resetBufferWatchdog();
    _player = player;
    _videoViewController = videoViewController;
    _videoUrl = videoUrl;
    _episode = episode;
    final requestedProgressUrl = progressUrl?.trim() ?? '';
    final episodeProgressUrl = episode?.url.trim() ?? '';
    _progressUrl = requestedProgressUrl.isNotEmpty
        ? requestedProgressUrl
        : (episodeProgressUrl.isNotEmpty ? episodeProgressUrl : videoUrl);
    _lastKnownPlaybackPositionMs = 0;
    _lastKnownPlaybackDurationMs = 0;
    _lastSavedPosition = Duration.zero;
    _pendingResumeSeekPosition = null;
    _isApplyingPendingResumeSeek = false;
    _userAddedExternalSubtitles.clear();
    pendingVideoViewSubtitleIdsBeforeReload = null;
    selectNewestVideoViewSubtitleAfterReload = false;
    _hasMarkedWatched = false;
    _hasRefreshedCloudProgress = false;
    _item = item;

    String initialTitle = item.title;
    final activeEpisode =
        episode ?? item.episodes?.firstWhereOrNull((e) => e.url == videoUrl);
    if (activeEpisode != null) {
      initialTitle = _titleWithEpisode(activeEpisode);
    }

    final imdbId =
        item.imdbId ?? item.syncData?['imdbId'] ?? item.syncData?['imdb_id'];
    final tmdbId = item.tmdbId;

    state = state.copyWith(
      playerTitle: initialTitle,
      activeEpisodeUrl: _progressUrl,
      imdbId: imdbId,
      tmdbId: tmdbId,
    );
    _enterStartupPhase(kind: PlaybackUiPhaseKind.bootstrapping);

    _setupEventDrivenProgressSaving();
    _setupErrorListener();
    _setupDurationListener();
    _setupBufferingMonitor();
    _setupRateListener();
    _setupVideoViewListeners();
    _setupConnectivityListener();

    state = state.copyWith(
      isLive:
          _item.contentType == MultimediaContentType.livestream ||
          _isLiveStream(_videoUrl),
    );

    _isInitialized = true;
    _maybeFetchSkipSegments();

    if (selectedSource != null && !selectedSource.requiresResolution) {
      final sourceSessionId = _beginSourceSession(resetAttempts: true);
      state = state.copyWith(
        streams: <StreamResult>[selectedSource],
        currentStreamIndex: 0,
      );
      _setSourceAttemptsFromStreams(<StreamResult>[selectedSource]);
      await loadStreamAtIndex(0, sourceSessionId: sourceSessionId);
    } else {
      if (selectedSource?.requiresResolution ?? false) {
        _videoUrl = selectedSource!.url;
      }
      await _initStream();
    }
    if (_isDisposed || !identical(_player, player)) return;
    await applySubtitleSettings();
    if (_isDisposed || !identical(_player, player)) return;

    final settings = ref.read(playerSettingsProvider).asData?.value;
    final defaultSpeed = settings?.defaultPlaybackSpeed ?? 1.0;
    if (defaultSpeed != 1.0 && !state.isLive) {
      await setPlaybackSpeed(defaultSpeed);
    }
  }

  void _maybeFetchSkipSegments() {
    unawaited(_fetchAndLogSkipSegments());
  }

  List<String> _skipCacheKeys() {
    final keys = <String>[];
    final episode = _episode;
    if (episode != null && episode.url.trim().isNotEmpty) {
      keys.add(SkipSegmentCache.keyForEpisodeUrl(episode.url));
    }
    final malId = _resolvedMalId;
    if (malId != null && episode != null) {
      keys.add(
        SkipSegmentCache.keyForMal(
          malId,
          episode.episode > 0 ? episode.episode : 1,
        ),
      );
    }
    return keys;
  }

  int? _currentDurationSeconds() {
    final dur = state.useExoPlayer
        ? Duration(
            milliseconds: _videoViewController?.mediaInfo.value?.duration ?? 0,
          )
        : _player.state.duration;
    return dur > Duration.zero ? dur.inSeconds : null;
  }

  Future<int?> _awaitDurationSeconds({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final immediate = _currentDurationSeconds();
    if (immediate != null) return immediate;

    final deadline = DateTime.now().add(timeout);
    while (!_isDisposed && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final value = _currentDurationSeconds();
      if (value != null) return value;
    }
    return _catalogRuntimeSeconds();
  }

  int? _catalogRuntimeSeconds() {
    final raw = _item.syncData?['awDuration']?.trim();
    final minutes = raw == null ? null : int.tryParse(raw);
    if (minutes == null || minutes <= 0) return null;
    return minutes * 60;
  }

  Future<void> _fetchAndLogSkipSegments() async {
    if (_episode == null) return;
    if (state.isLive || _item.contentType == MultimediaContentType.livestream) {
      return;
    }

    final skipEnabled =
        ref
            .read(settingsRepositoryProvider)
            .getPlayerSetting<bool>(
              'player_skip_segments',
              defaultValue: true,
            ) ??
        true;
    if (!skipEnabled) return;

    final malId = int.tryParse(
      (_item.syncData?['malId'] ?? _item.syncData?['mal_id'] ?? '').trim(),
    );

    final hasNoIds =
        state.tmdbId == null &&
        state.imdbId == null &&
        malId == null &&
        _item.syncData?['anilist'] == null &&
        _item.syncData?['anilistId'] == null &&
        _item.syncData?['anilist_id'] == null;

    final cache = ref.read(skipSegmentCacheProvider);
    final cached = cache.readAny(_skipCacheKeys());
    if (cached.isNotEmpty) {
      state = state.copyWith(skipSegments: cached);
    }

    if (hasNoIds && _item.title.trim().isEmpty) return;

    var introDbSegments = const <SkipSegment>[];
    var aniSkipSegments = const <SkipSegment>[];
    var chapterSegments = const <SkipSegment>[];
    final int season = _episode!.season > 0 ? _episode!.season : 1;
    final int episodeNum = _episode!.episode > 0 ? _episode!.episode : 1;

    if (state.tmdbId != null || state.imdbId != null) {
      try {
        introDbSegments = await ref.read(introDbServiceProvider).getSkipSegments(
          tmdbId: state.tmdbId,
          imdbId: state.imdbId,
          season: season,
          episode: episodeNum,
        );
      } catch (_) {}
    }

    if (_isDisposed) return;

    final isAnime =
        _item.contentType == MultimediaContentType.anime ||
        malId != null ||
        _item.syncData?['anilist'] != null ||
        _item.syncData?['anilistId'] != null ||
        _item.syncData?['anilist_id'] != null ||
        (_item.tags != null &&
            _item.tags!.any(
              (t) =>
                  t.toLowerCase() == 'anime' || t.toLowerCase() == 'animation',
            ));

    if (isAnime) {
      var resolvedMalId = malId;
      if (resolvedMalId == null && _item.title.trim().isNotEmpty) {
        resolvedMalId = await ref
            .read(malIdResolverProvider)
            .resolve(_item.title);
        if (_isDisposed) return;
      }
      _resolvedMalId = resolvedMalId;

      if (resolvedMalId != null) {
        try {
          final durationSec = await _awaitDurationSeconds();
          if (_isDisposed) return;
          aniSkipSegments = await ref
              .read(aniSkipServiceProvider)
              .getSkipSegments(
                malId: resolvedMalId,
                season: season,
                episode: episodeNum,
                duration: durationSec,
              );
          if (_isDisposed) return;
        } catch (_) {}
      }

      if (_isDisposed) return;

      if (introDbSegments.isEmpty && resolvedMalId != null) {
        try {
          final ids = await ref
              .read(animeIdMappingsProvider)
              .byMalId(resolvedMalId);
          if (_isDisposed) return;
          if (ids != null && (ids.imdbId != null || ids.tmdbId != null)) {
            final durationSec = await _awaitDurationSeconds();
            if (_isDisposed) return;
            introDbSegments = await ref
                .read(introDbServiceProvider)
                .getSkipSegments(
                  imdbId: ids.imdbId,
                  tmdbId: ids.tmdbId,
                  season: season,
                  episode: episodeNum,
                  duration: durationSec,
                );
            if (_isDisposed) return;
          }
        } catch (_) {}
      }
    }

    final durationSec = await _awaitDurationSeconds();
    if (_isDisposed) return;
    try {
      chapterSegments = await ChapterSkipSource.read(
        _player,
        durationSec: durationSec?.toDouble(),
      );
      if (_isDisposed) return;
    } catch (_) {}

    final merged = SkipSegment.merge(<List<SkipSegment>>[
      aniSkipSegments,
      introDbSegments,
      chapterSegments,
    ], durationSec: durationSec?.toDouble());

    if (merged.isNotEmpty && !_isDisposed) {
      state = state.copyWith(skipSegments: merged);
      unawaited(cache.write(_skipCacheKeys(), merged));
    }
  }

  void _setupVideoViewListeners() {
    if (_videoViewController == null) return;

    _videoViewController!.mediaInfo.addListener(() {
      final info = _videoViewController!.mediaInfo.value;
      if (info != null) {
        final detectedIsLive =
            _item.contentType == MultimediaContentType.livestream
            ? true
            : info.isLive;
        if (info.isSeekable != state.isSeekable ||
            detectedIsLive != state.isLive) {
          state = state.copyWith(
            isSeekable: info.isSeekable,
            isLive: detectedIsLive,
          );
        }

        if (!_hasConfirmedPlaybackFrame &&
            (info.duration > 0 || info.isLive) &&
            state.uiPhase.kind == PlaybackUiPhaseKind.openingSource) {
          _enterStartupPhase(kind: PlaybackUiPhaseKind.bufferingInitial);
        }

        if ((info.duration > 0 || info.isLive) &&
            _suppressNextEpisodeDetection) {
          _suppressNextEpisodeDetection = false;
        }

        if (selectNewestVideoViewSubtitleAfterReload &&
            info.subtitleTracks.isNotEmpty) {
          final previousIds =
              pendingVideoViewSubtitleIdsBeforeReload ?? const <String>{};
          final newTrackId =
              info.subtitleTracks.keys.firstWhereOrNull(
                (id) => !previousIds.contains(id),
              ) ??
              info.subtitleTracks.keys.lastOrNull;
          if (newTrackId != null) {
            _videoViewController!.setShowSubtitle(true);
            _videoViewController!.setOverrideSubtitle(newTrackId);
          }
          pendingVideoViewSubtitleIdsBeforeReload = null;
          selectNewestVideoViewSubtitleAfterReload = false;
        }
      }
    });

    _videoViewController!.loading.addListener(() {
      final isLoading = _videoViewController!.loading.value;
      _onBufferingChanged(isLoading);
      if (isLoading) {
        _handleBufferStall();
        _bufferingHideTimer?.cancel();
        _stallTimer?.cancel();
        _stallTimer = Timer(const Duration(milliseconds: 400), () {
          if (_hasConfirmedPlaybackFrame) {
            _enterRuntimePhase(kind: PlaybackUiPhaseKind.bufferingRuntime);
          } else {
            _enterStartupPhase(kind: PlaybackUiPhaseKind.bufferingInitial);
          }
        });
      } else {
        _stallTimer?.cancel();
        if (_hasConfirmedPlaybackFrame &&
            state.uiPhase.kind == PlaybackUiPhaseKind.bufferingRuntime) {
          _bufferingHideTimer?.cancel();
          _bufferingHideTimer = Timer(const Duration(milliseconds: 200), () {
            if (state.uiPhase.kind == PlaybackUiPhaseKind.bufferingRuntime) {
              _setIdlePhase();
            }
          });
        }
      }
    });

    _videoViewController!.error.addListener(() {
      final error = _videoViewController!.error.value;
      if (error != null) {
        pendingVideoViewSubtitleIdsBeforeReload = null;
        selectNewestVideoViewSubtitleAfterReload = false;
        if (_isAppBackgrounded) return;
        if (!_hasConfirmedPlaybackFrame ||
            (_videoViewController!.position.value) == 0) {
          _markSourceAttempt(
            state.currentStreamIndex,
            SourceAttemptStatus.failed,
          );
          if (_manualSelectionPending) {
            _manualSelectionPending = false;
            revertToPreviousStream(
              _playerText(
                english: 'Selected source is not playable. Reverting back to previous source.',
                arabic: 'المصدر المحدد غير قابل للتشغيل. جارٍ الرجوع إلى المصدر السابق.',
              ),
            );
          } else {
            unawaited(retryNextStream(sourceSessionId: state.sourceSessionId));
          }
        } else {
          if (state.isLive && state.currentStream != null) {
            if (_isRecoveringFromStall) return;
            _enterRuntimePhase(kind: PlaybackUiPhaseKind.reconnectingLive);
            _beginStallRecovery(
              perform: changeStream(state.currentStream!, resetPosition: true),
            );
            return;
          }
          if (_isReconnectingCurrentStream) return;
          if (state.currentStream != null) {
            _requestMidPlaybackReconnect();
            return;
          }
          _markSourceAttempt(
            state.currentStreamIndex,
            SourceAttemptStatus.failed,
          );
          _revertMessage = _playerText(
            english: 'Current source stopped unexpectedly. Trying next available source...',
            arabic: 'توقف المصدر الحالي بشكل غير متوقع. جارٍ تجربة المصدر التالي المتاح...',
          );
          unawaited(retryNextStream(sourceSessionId: state.sourceSessionId));
        }
      }
    });

    _videoViewController!.playbackState.addListener(() {
      final playing =
          _videoViewController!.playbackState.value ==
          VideoControllerPlaybackState.playing;
      if (!playing) {
        saveProgress();
        _stallTimer?.cancel();
        _bufferingHideTimer?.cancel();
        if (state.uiPhase.kind == PlaybackUiPhaseKind.bufferingRuntime) {
          _setIdlePhase();
        }
      }
    });

    _videoViewController!.finishedTimes.addListener(() {
      final completions = _videoViewController!.finishedTimes.value;
      if (completions > 0) {
        final isLive =
            _item.contentType == MultimediaContentType.livestream ||
            _isLiveStream(_videoUrl);
        if (isLive && state.currentStream != null) {
          _enterRuntimePhase(kind: PlaybackUiPhaseKind.reconnectingLive);
          unawaited(changeStream(state.currentStream!, resetPosition: true));
        }
      }
    });

    _videoViewController!.position.addListener(() {
      if (!state.useExoPlayer) return;

      final posMs = _videoViewController!.position.value;
      final durationMs = _videoViewController!.mediaInfo.value?.duration ?? 0;
      if (posMs > 0) _lastKnownPlaybackPositionMs = posMs;
      if (durationMs >= 30000) _lastKnownPlaybackDurationMs = durationMs;

      _maybeConfirmPlaybackStarted(posMs);

      if (_midPlaybackRetryCount > 0 &&
          _videoViewController!.playbackState.value ==
              VideoControllerPlaybackState.playing) {
        _midPlaybackRetryCount = 0;
        _isReconnectingCurrentStream = false;
        _midPlaybackRetryTimer?.cancel();
      }

      if (durationMs == 0) return;

      final currentPct = posMs / durationMs;
      final lastPct = _lastSavedPosition.inMilliseconds / durationMs;

      if ((currentPct - lastPct).abs() >= _saveThresholdPercent) {
        saveProgress();
        _lastSavedPosition = Duration(milliseconds: posMs);
      }

      if (!_suppressNextEpisodeDetection &&
          (_item.contentType == MultimediaContentType.series ||
              _item.contentType == MultimediaContentType.anime)) {
        final remainingSecs = (durationMs - posMs) / 1000;
        if (remainingSecs <= 15.0) {
          final currentEp = _episode ?? _resolveCurrentEpisode();
          List<Episode>? episodes = _item.episodes;
          if (isSeries &&
              currentEp != null &&
              currentEp.dubStatus != DubStatus.none) {
            episodes = episodes
                ?.where((e) => e.dubStatus == currentEp.dubStatus)
                .toList();
          }

          int? currentIndex;
          if (currentEp != null) {
            currentIndex = episodes?.indexWhere((e) => e.url == currentEp.url);
          } else {
            currentIndex = episodes?.indexWhere((e) => e.url == _videoUrl);
          }
          if (currentIndex != null &&
              currentIndex != -1 &&
              episodes != null &&
              currentIndex < episodes.length - 1) {
            final next = episodes[currentIndex + 1];
            if (!_userDismissedOverlay && !state.showNextEpisodeOverlay) {
              state = state.copyWith(
                showNextEpisodeOverlay: true,
                nextEpisodeTitle: next.name,
                nextEpisodePosterUrl: _episodeArtwork(next),
                nextEpisodeRating: next.rating,
                nextEpisodeNumber: next.episode,
                nextEpisodeSeason: next.season,
                nextEpisodeRuntime: next.runtime,
                nextEpisodeDescription: next.description,
                nextEpisodeIsFinal: next.isFinal,
                nextEpisodeServerName: next.serverName,
              );
            }
            _warmNextEpisodeSources(next);
            _isNextEpisodeOverlayForced = true;
          }
          return;
        }

        if (remainingSecs > 15.0) {
          if (state.showNextEpisodeOverlay && !_isNextEpisodeOverlayForced) {
            state = state.copyWith(showNextEpisodeOverlay: false);
          }
        }
      }
    });
  }

  void forceNextEpisodeOverlay() {
    if (_item.contentType != MultimediaContentType.series &&
        _item.contentType != MultimediaContentType.anime) {
      return;
    }
    if (_userDismissedOverlay) return;

    final currentEp = _episode ?? _resolveCurrentEpisode();
    List<Episode>? episodes = _item.episodes;
    if (isSeries &&
        currentEp != null &&
        currentEp.dubStatus != DubStatus.none) {
      episodes = episodes
          ?.where((e) => e.dubStatus == currentEp.dubStatus)
          .toList();
    }

    int? currentIndex;
    if (currentEp != null) {
      currentIndex = episodes?.indexWhere((e) => e.url == currentEp.url);
    } else {
      currentIndex = episodes?.indexWhere((e) => e.url == _videoUrl);
    }

    if (currentIndex != null &&
        currentIndex != -1 &&
        episodes != null &&
        currentIndex < episodes.length - 1) {
      final next = episodes[currentIndex + 1];
      _isNextEpisodeOverlayForced = true;
      state = state.copyWith(
        showNextEpisodeOverlay: true,
        nextEpisodeTitle: next.name,
        nextEpisodePosterUrl: _episodeArtwork(next),
        nextEpisodeRating: next.rating,
        nextEpisodeNumber: next.episode,
        nextEpisodeSeason: next.season,
        nextEpisodeRuntime: next.runtime,
        nextEpisodeDescription: next.description,
        nextEpisodeIsFinal: next.isFinal,
        nextEpisodeServerName: next.serverName,
      );
    }
  }

  void _setupRateListener() {
    _rateSub?.cancel();
    _rateSub = _player.stream.rate.listen((rate) {
      state = state.copyWith(playbackSpeed: rate);
    });
  }

  void _setupDurationListener() {
    _durationSub?.cancel();
    _durationSub = _player.stream.duration.listen((duration) {
      if (duration.inMilliseconds >= 30000) {
        _lastKnownPlaybackDurationMs = duration.inMilliseconds;
      }
      if (duration > Duration.zero) {
        if (_pendingResumeSeekPosition != null) {
          unawaited(_flushPendingResumeSeek());
        }
        if (_suppressNextEpisodeDetection) {
          _suppressNextEpisodeDetection = false;
        }
      }
    });
  }

  void _setupBufferingMonitor() {
    _bufferingSub?.cancel();
    _bufferingSub = _player.stream.buffering.listen((isBuffering) {
      _onBufferingChanged(isBuffering);
      if (isBuffering) {
        _handleBufferStall();
        _bufferingHideTimer?.cancel();
        _stallTimer?.cancel();
        _stallTimer = Timer(const Duration(milliseconds: 400), () {
          if (_hasConfirmedPlaybackFrame) {
            _enterRuntimePhase(kind: PlaybackUiPhaseKind.bufferingRuntime);
          } else {
            _enterStartupPhase(kind: PlaybackUiPhaseKind.bufferingInitial);
          }
        });
      } else {
        _stallTimer?.cancel();
        if (_hasConfirmedPlaybackFrame &&
            state.uiPhase.kind == PlaybackUiPhaseKind.bufferingRuntime) {
          _bufferingHideTimer?.cancel();
          _bufferingHideTimer = Timer(const Duration(milliseconds: 200), () {
            if (state.uiPhase.kind == PlaybackUiPhaseKind.bufferingRuntime) {
              _setIdlePhase();
            }
          });
        }
      }
    });
  }

  Duration get _currentPosition => state.useExoPlayer
      ? Duration(milliseconds: _videoViewController?.position.value ?? 0)
      : _player.state.position;

  void _onBufferingChanged(bool isBuffering) {
    if (!isBuffering) {
      _resetBufferWatchdog();
      return;
    }
    _bufferingSince ??= DateTime.now();
    _bufferingStartPosition ??= _currentPosition;
    _bufferWatchdogTimer ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => _checkBufferWatchdog(),
    );
  }

  void _checkBufferWatchdog() {
    final since = _bufferingSince;
    if (since == null) return;
    if (!_hasConfirmedPlaybackFrame) return;
    if (state.isLive) return;
    if (_isRecoveringFromStall) return;

    final position = _currentPosition;
    final startedAt = _bufferingStartPosition;
    if (startedAt != null &&
        (position - startedAt).abs() > const Duration(seconds: 1)) {
      _bufferingSince = DateTime.now();
      _bufferingStartPosition = position;
      _bufferRecoveryStage = 0;
      return;
    }

    final stuckFor = DateTime.now().difference(since);
    if (_bufferRecoveryStage == 0 &&
        stuckFor >= PlaybackRecoveryPolicy.bufferNudgeAfter) {
      _bufferRecoveryStage = 1;
      unawaited(() async {
        await _safeSeekTo(position.inMilliseconds);
        await play();
      }());
      return;
    }

    if (_bufferRecoveryStage == 1 &&
        stuckFor >= PlaybackRecoveryPolicy.reopenSourceAfter) {
      _bufferRecoveryStage = 2;
      final current = state.currentStream;
      if (current == null) return;
      _enterRuntimePhase(kind: PlaybackUiPhaseKind.bufferingRuntime);
      _beginStallRecovery(perform: changeStream(current, resetPosition: false));
      return;
    }

    if (_bufferRecoveryStage == 2 &&
        stuckFor >= PlaybackRecoveryPolicy.failoverSourceAfter) {
      _bufferRecoveryStage = 3;
      _resetBufferWatchdog();
      _resetMidPlaybackReconnect();
      _revertMessage = _playerText(
        english: 'This source stopped responding after the seek. Trying the next one…',
        arabic: 'توقف هذا المصدر عن الاستجابة بعد التقديم. جارٍ تجربة المصدر التالي…',
      );
      unawaited(retryNextStream(sourceSessionId: state.sourceSessionId));
    }
  }

  void _handleBufferStall() {
    if (!_hasConfirmedPlaybackFrame) return;
    if (_isLiveStream(_videoUrl)) return;

    final now = DateTime.now();
    _bufferDepletionTimes.add(now);
    _bufferDepletionTimes.removeWhere(
      (t) => now.difference(t) > const Duration(seconds: 60),
    );

    if (_bufferDepletionTimes.length >= 2 && !state.isAdaptiveBufferingActive) {
      state = state.copyWith(isAdaptiveBufferingActive: true);
      if (_player.platform is NativePlayer) {
        final settings = ref.read(playerSettingsProvider).asData?.value;
        final readahead = (settings?.readaheadSeconds ?? 180) * 2;
        final native = _player.platform as NativePlayer;
        if (_player.state.duration > Duration.zero) {
          native.setProperty('demuxer-readahead-secs', '$readahead');
          native.setProperty('cache-secs', '$readahead');
        }
      }
    }
  }

  void _setupErrorListener() {
    _trackSub?.cancel();
    _trackSub = _player.stream.track.listen((track) {
      final id = track.audio.id.toString();
      if (id != 'no' && id != 'auto') {
        _lastKnownAudioTrackId = id;
      }
    });

    _errorSub = _player.stream.error.listen((error) {
      if (error.toString().toLowerCase().contains('abort')) return;

      final isAudioDecodeError = error.toString().toLowerCase().contains(
        'decoding audio',
      );
      final isVideoDecodeError = error.toString().toLowerCase().contains(
        'decoding video',
      );
      if (isVideoDecodeError &&
          !state.isLive &&
          _hasConfirmedPlaybackFrame &&
          _player.state.position > Duration.zero) {
        return;
      }

      if (isAudioDecodeError && !state.isLive) {
        final now = DateTime.now();
        if (_audioFailoverLastTime != null &&
            now.difference(_audioFailoverLastTime!) <
                const Duration(milliseconds: 500)) {
          return;
        }
        _audioFailoverLastTime = now;

        if (_lastKnownAudioTrackId != null) {
          _failedAudioTrackIds.add(_lastKnownAudioTrackId!);
        } else {
          final firstReal = _player.state.tracks.audio.firstWhereOrNull(
            (t) => t.id != 'no' && t.id != 'auto',
          );
          if (firstReal != null) {
            _failedAudioTrackIds.add(firstReal.id.toString());
          }
        }
        final nextTrack = _player.state.tracks.audio.firstWhereOrNull(
          (t) =>
              t.id != 'no' &&
              t.id != 'auto' &&
              !_failedAudioTrackIds.contains(t.id.toString()),
        );
        if (nextTrack != null) {
          _lastKnownAudioTrackId = nextTrack.id.toString();
          _player.setAudioTrack(nextTrack).catchError((_) {});
          return;
        }
        final noTrack = _player.state.tracks.audio.firstWhereOrNull(
          (t) => t.id == 'no',
        );
        if (noTrack != null) {
          _player.setAudioTrack(noTrack).catchError((_) {});
        }
        return;
      }

      if (!_hasConfirmedPlaybackFrame ||
          _player.state.position == Duration.zero) {
        final errLower = error.toString().toLowerCase();
        final looksLikeDecodeFailure =
            errLower.contains('decod') ||
            errLower.contains('codec') ||
            errLower.contains('hwdec') ||
            errLower.contains('hardware') ||
            errLower.contains('mediacodec') ||
            errLower.contains('vo ') ||
            errLower.contains('video output');
        if (looksLikeDecodeFailure &&
            !_forceSoftwareDecode &&
            state.currentStream != null) {
          _forceSoftwareDecode = true;
          unawaited(changeStream(state.currentStream!, resetPosition: true));
          return;
        }

        _markSourceAttempt(
          state.currentStreamIndex,
          SourceAttemptStatus.failed,
        );
        if (_manualSelectionPending) {
          _manualSelectionPending = false;
          revertToPreviousStream(
            _playerText(
              english: 'Selected source failed. Reverting...',
              arabic: 'فشل المصدر المحدد. جارٍ الرجوع...',
            ),
          );
        } else {
          retryNextStream(sourceSessionId: state.sourceSessionId);
        }
      } else {
        if (_isAppBackgrounded) return;
        if (state.isLive && state.currentStream != null) {
          if (_isRecoveringFromStall) return;
          _enterRuntimePhase(kind: PlaybackUiPhaseKind.reconnectingLive);
          _beginStallRecovery(
            perform: changeStream(state.currentStream!, resetPosition: true),
          );
          return;
        }
        if (_isReconnectingCurrentStream) return;
        if (state.currentStream != null) {
          _requestMidPlaybackReconnect();
          return;
        }

        _markSourceAttempt(
          state.currentStreamIndex,
          SourceAttemptStatus.failed,
        );
        _revertMessage = _playerText(
          english: 'Current source stopped unexpectedly. Trying next available source...',
          arabic: 'توقف المصدر الحالي بشكل غير متوقع. جارٍ تجربة المصدر التالي المتاح...',
        );
        retryNextStream(sourceSessionId: state.sourceSessionId);
      }
    });
  }

  void _setupConnectivityListener() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final isConnected = results.any((r) => r != ConnectivityResult.none);
      if (!isConnected) return;
      if (!_hasConfirmedPlaybackFrame) return;
      final waitingOnBackoff = _midPlaybackRetryTimer != null;
      final buffering =
          state.uiPhase.kind == PlaybackUiPhaseKind.bufferingRuntime;
      if (_isReconnectingCurrentStream && !waitingOnBackoff) return;
      if (_isReconnectingCurrentStream || buffering || waitingOnBackoff) {
        _requestMidPlaybackReconnect(preferImmediate: true);
      }
    });
  }

  void _requestMidPlaybackReconnect({bool preferImmediate = false}) {
    if (_isDisposed || state.currentStream == null) return;
    if (state.isLive) return;
    if (_isReconnectingCurrentStream) return;
    if (preferImmediate) {
      _midPlaybackRetryTimer?.cancel();
      _midPlaybackRetryTimer = null;
    } else if (_midPlaybackRetryTimer != null) {
      return;
    }
    if (!PlaybackRecoveryPolicy.canReconnect(_midPlaybackRetryCount)) {
      _failoverAfterReconnectBudget();
      return;
    }
    unawaited(_triggerMidPlaybackReconnect());
  }

  void _failoverAfterReconnectBudget() {
    _resetMidPlaybackReconnect();
    _resetBufferWatchdog();
    if (state.currentStream == null) return;
    _markSourceAttempt(state.currentStreamIndex, SourceAttemptStatus.failed);
    _revertMessage = _playerText(
      english: 'Current source stopped unexpectedly. Trying next available source...',
      arabic: 'توقف المصدر الحالي بشكل غير متوقع. جارٍ تجربة المصدر التالي المتاح...',
    );
    unawaited(retryNextStream(sourceSessionId: state.sourceSessionId));
  }

  Future<void> _triggerMidPlaybackReconnect({
    bool consumeRetryBudget = true,
  }) async {
    if (state.currentStream == null || _isDisposed) return;
    if (_isReconnectingCurrentStream) return;

    if (consumeRetryBudget &&
        !PlaybackRecoveryPolicy.canReconnect(_midPlaybackRetryCount)) {
      _failoverAfterReconnectBudget();
      return;
    }

    _isReconnectingCurrentStream = true;
    if (consumeRetryBudget) _midPlaybackRetryCount++;

    bool hasConnection = true;
    try {
      final results = await Connectivity().checkConnectivity();
      hasConnection = results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      hasConnection = true;
    }

    if (!hasConnection) {
      if (consumeRetryBudget && _midPlaybackRetryCount > 0) {
        _midPlaybackRetryCount--;
      }
      _isReconnectingCurrentStream = false;
      _enterRuntimePhase(kind: PlaybackUiPhaseKind.bufferingRuntime);
      return;
    }

    final oldPos = state.useExoPlayer
        ? Duration(milliseconds: _videoViewController?.position.value ?? 0)
        : _player.state.position;

    _enterRuntimePhase(kind: PlaybackUiPhaseKind.bufferingRuntime);

    try {
      final stream = state.currentStream!;
      final playUrl = await _resolveStreamUrl(stream, forceRefresh: true);
      if (playUrl == null) throw Exception('Failed to re-resolve stream URL');
      if (_isDisposed) return;

      final current = state.currentStream ?? stream;
      final headers = _buildPlaybackHeaders(current);
      final resolvedIsLive = _detectResolvedLiveState(playUrl);
      final useVideoView = _canUseVideoViewForStream(
        playUrl,
        current,
        isLive: resolvedIsLive,
      );

      await _applyPlaybackProperties(
        headers,
        current,
        useVideoView: useVideoView,
      );
      if (_isDisposed) return;

      final holdPosition = oldPos > Duration.zero;
      await _openResolvedStream(
        playUrl,
        current,
        headers,
        useVideoView: useVideoView,
        play: !holdPosition,
      );
      if (_isDisposed) return;

      if (holdPosition) {
        await _seekThenPlay(oldPos.inMilliseconds);
      }
      _isReconnectingCurrentStream = false;
    } catch (e) {
      _isReconnectingCurrentStream = false;
      if (!consumeRetryBudget) return;
      if (PlaybackRecoveryPolicy.isPermanentPlaybackError(e) ||
          !PlaybackRecoveryPolicy.canReconnect(_midPlaybackRetryCount)) {
        _failoverAfterReconnectBudget();
        return;
      }
      final delay = PlaybackRecoveryPolicy.reconnectBackoff(
        _midPlaybackRetryCount,
      );
      if (delay == null) {
        _failoverAfterReconnectBudget();
        return;
      }
      _midPlaybackRetryTimer?.cancel();
      _midPlaybackRetryTimer = Timer(delay, () {
        if (!_isDisposed && state.currentStream != null) {
          unawaited(_triggerMidPlaybackReconnect());
        }
      });
    }
  }

  void _setupEventDrivenProgressSaving() {
    _playingSub?.cancel();
    _playingSub = _player.stream.playing.listen((isPlaying) {
      if (!isPlaying) {
        saveProgress();
        _stallTimer?.cancel();
        _bufferingHideTimer?.cancel();
        if (state.uiPhase.kind == PlaybackUiPhaseKind.bufferingRuntime) {
          _setIdlePhase();
        }
      }
    });

    _completedSub?.cancel();
    _completedSub = _player.stream.completed.listen((isCompleted) {
      if (isCompleted) {
        final isLive =
            _item.contentType == MultimediaContentType.livestream ||
            _isLiveStream(_videoUrl);
        if (isLive && state.currentStream != null) {
          _enterRuntimePhase(kind: PlaybackUiPhaseKind.reconnectingLive);
          unawaited(changeStream(state.currentStream!, resetPosition: true));
        }
      }
    });

    _positionSub?.cancel();
    _positionSub = _player.stream.position.listen((pos) {
      _maybeConfirmPlaybackStarted(pos.inMilliseconds);

      final now = DateTime.now();
      if (_player.state.playing && !state.isBuffering && !state.isLoading) {
        if (_lastPosition != null && _lastPosition == pos) {
          final stallDuration = _lastPositionUpdateTime != null
              ? now.difference(_lastPositionUpdateTime!)
              : Duration.zero;

          if (stallDuration.inSeconds >= 5 && !_isRecoveringFromStall) {
            if (state.isLive && state.currentStream != null) {
              _beginStallRecovery(
                perform: changeStream(
                  state.currentStream!,
                  resetPosition: true,
                ),
              );
            } else {
              _beginStallRecovery();
              _player.play();
            }
          }
        } else {
          _lastPosition = pos;
          _lastPositionUpdateTime = now;
          if (_midPlaybackRetryCount > 0) {
            _midPlaybackRetryCount = 0;
            _isReconnectingCurrentStream = false;
            _midPlaybackRetryTimer?.cancel();
          }
        }
      } else {
        _lastPosition = pos;
        _lastPositionUpdateTime = now;
      }

      if (pos.inMilliseconds > 0) {
        _lastKnownPlaybackPositionMs = pos.inMilliseconds;
      }
      final duration = _player.state.duration;
      if (duration.inMilliseconds >= 30000) {
        _lastKnownPlaybackDurationMs = duration.inMilliseconds;
      }
      if (duration == Duration.zero) return;

      final currentPct = pos.inMilliseconds / duration.inMilliseconds;
      final lastPct =
          _lastSavedPosition.inMilliseconds / duration.inMilliseconds;

      if ((currentPct - lastPct).abs() >= _saveThresholdPercent) {
        saveProgress();
        _lastSavedPosition = pos;
      }

      if (!_suppressNextEpisodeDetection &&
          (_item.contentType == MultimediaContentType.series ||
              _item.contentType == MultimediaContentType.anime)) {
        final durationMs = duration.inMilliseconds;
        final posMs = pos.inMilliseconds;
        final remainingSecs = (durationMs - posMs) / 1000;

        if (remainingSecs <= 15.0) {
          final currentEp = _episode ?? _resolveCurrentEpisode();
          List<Episode>? episodes = _item.episodes;
          if (isSeries &&
              currentEp != null &&
              currentEp.dubStatus != DubStatus.none) {
            episodes = episodes
                ?.where((e) => e.dubStatus == currentEp.dubStatus)
                .toList();
          }

          int? currentIndex;
          if (currentEp != null) {
            currentIndex = episodes?.indexWhere((e) => e.url == currentEp.url);
          } else {
            currentIndex = episodes?.indexWhere((e) => e.url == _videoUrl);
          }
          if (currentIndex != null &&
              currentIndex != -1 &&
              episodes != null &&
              currentIndex < episodes.length - 1) {
            final next = episodes[currentIndex + 1];
            if (!_userDismissedOverlay && !state.showNextEpisodeOverlay) {
              state = state.copyWith(
                showNextEpisodeOverlay: true,
                nextEpisodeTitle: next.name,
                nextEpisodePosterUrl: _episodeArtwork(next),
                nextEpisodeRating: next.rating,
                nextEpisodeNumber: next.episode,
                nextEpisodeSeason: next.season,
                nextEpisodeRuntime: next.runtime,
                nextEpisodeDescription: next.description,
                nextEpisodeIsFinal: next.isFinal,
                nextEpisodeServerName: next.serverName,
              );
            }
            _warmNextEpisodeSources(next);
            _isNextEpisodeOverlayForced = true;
          }
          return;
        }

        if (remainingSecs > 15.0 &&
            state.showNextEpisodeOverlay &&
            !_isNextEpisodeOverlayForced) {
          state = state.copyWith(showNextEpisodeOverlay: false);
        }
      }
    });
  }

  Future<void> _initStream({
    PlaybackUiPhaseKind requestedPhaseKind =
        PlaybackUiPhaseKind.fetchingSources,
    bool forceNewSourceSession = true,
  }) async {
    final sourceSessionId = forceNewSourceSession
        ? _beginSourceSession(resetAttempts: true)
        : state.sourceSessionId;

    switch (requestedPhaseKind) {
      case PlaybackUiPhaseKind.loadingNextEpisode:
        _enterStartupPhase(kind: PlaybackUiPhaseKind.loadingNextEpisode);
        break;
      case PlaybackUiPhaseKind.switchingSource:
        _enterRuntimePhase(kind: PlaybackUiPhaseKind.switchingSource);
        break;
      case PlaybackUiPhaseKind.reconnectingLive:
        _enterRuntimePhase(kind: PlaybackUiPhaseKind.reconnectingLive);
        break;
      default:
        _enterStartupPhase(kind: requestedPhaseKind);
    }

    if (await _handleSpecialProviders()) return;

    final activeProvider = _resolveProvider();
    if (activeProvider == null) {
      state = state.copyWith(
        errorMessage: _playerText(
          english: 'No provider selected.',
          arabic: 'لم يتم اختيار مزوّد.',
        ),
      );
      return;
    }

    try {
      if (_videoUrl.isNotEmpty) {
        final rawStreams = await activeProvider.loadStreams(_videoUrl);
        if (!_isCurrentSourceSession(sourceSessionId)) return;
        if (rawStreams.isNotEmpty) {
          final explicitSelection = activeProvider.isExplicitStreamSelection(
            _videoUrl,
          );
          final streams = rawStreams;

          final initialIndex = explicitSelection
              ? 0
              : _findSavedStreamIndex(streams);
          state = state.copyWith(
            streams: streams,
            currentStreamIndex: initialIndex,
          );
          final checkCount = explicitSelection
              ? 1
              : (streams.length > 3 ? 3 : streams.length);

          _setSourceAttemptsFromStreams(streams);
          if (checkCount > 1) {
            final batchIndices = {
              for (int i = 0; i < checkCount; i++)
                (initialIndex + i) % streams.length,
            };
            final updated = state.sourceAttempts
                .map(
                  (e) => batchIndices.contains(e.index)
                      ? e.copyWith(status: SourceAttemptStatus.trying)
                      : e,
                )
                .toList();
            state = state.copyWith(sourceAttempts: updated);
          } else {
            _markSourceAttempt(initialIndex, SourceAttemptStatus.trying);
          }

          _enterStartupPhase(kind: PlaybackUiPhaseKind.checkingSources);
          final workingIndex = await _findFirstWorkingStream(
            streams,
            startIndex: initialIndex,
            limit: checkCount,
            sourceSessionId: sourceSessionId,
          );
          if (!_isCurrentSourceSession(sourceSessionId)) return;

          await loadStreamAtIndex(
            workingIndex,
            sourceSessionId: sourceSessionId,
          );
          return;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error loading streams: $e');
    }

    if (!_isCurrentSourceSession(sourceSessionId)) return;
    state = state.copyWith(
      errorMessage: _playerText(
        english: 'No streams found.',
        arabic: 'لم يتم العثور على مصادر تشغيل.',
      ),
    );
  }

  Future<bool> _handleSpecialProviders() async {
    if (_item.provider == 'Remote' ||
        _item.provider == 'Local' ||
        AppUtils.isLocalFile(_videoUrl)) {
      final stream = StreamResult(
        url: _videoUrl,
        source: 'Video',
        headers: const <String, String>{},
      );
      state = state.copyWith(
        streams: <StreamResult>[stream],
        currentStreamIndex: 0,
      );
      _setSourceAttemptsFromStreams(<StreamResult>[stream], activeIndex: 0);
      await loadStreamAtIndex(0, sourceSessionId: state.sourceSessionId);
      return true;
    }
    return false;
  }

  AnimeWitcherProvider? _resolveProvider() {
    final activeState = ref.read(activeProviderProvider);
    final manager = ref.read(extensionManagerProvider.notifier);

    if (_item.provider != null) {
      try {
        final val = _item.provider!;
        return manager.getAllProviders().firstWhere(
          (p) => p.packageName == val || p.name == val,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('PlayerController._resolveProvider: $e');
      }
    }
    return activeState;
  }

  int _findSavedStreamIndex(List<StreamResult> streams) {
    try {
      final historyRepo = ref.read(historyRepositoryProvider);
      final isSeries =
          (_item.contentType == MultimediaContentType.series ||
          _item.contentType == MultimediaContentType.anime);

      String? lastUrl;
      if (isSeries) {
        lastUrl = historyRepo.getLastStreamUrl(_item.url);
      }

      if (lastUrl == null) {
        final continueList = ref.read(continueWatchingProvider);
        final previousState = continueList.firstWhere(
          (h) => h.item.url == _item.url,
          orElse: () => HistoryItem(
            item: _item,
            position: 0,
            duration: 0,
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        lastUrl = previousState.lastStreamUrl;
      }

      if (lastUrl != null) {
        final foundIndex = streams.indexWhere((s) => s.url == lastUrl);
        if (foundIndex != -1) return foundIndex;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Error checking saved stream quality: $e');
    }
    return 0;
  }

  Episode? _resolveCurrentEpisode() {
    if (_episode != null) return _episode;
    if (!hasEpisodePicker) return null;
    return _item.episodes?.firstWhereOrNull((e) => e.url == _videoUrl);
  }

  String get _currentProgressUrl {
    final episodeUrl = _episode?.url.trim() ?? '';
    if (episodeUrl.isNotEmpty) return episodeUrl;
    final canonical = _progressUrl.trim();
    return canonical.isNotEmpty ? canonical : _videoUrl;
  }

  List<SubtitleFile> _effectiveExternalSubtitles(
    List<SubtitleFile>? streamSubtitles,
  ) {
    final merged = <SubtitleFile>[];
    final seenUrls = <String>{};

    for (final sub in [...?streamSubtitles, ..._userAddedExternalSubtitles]) {
      if (seenUrls.add(sub.url)) merged.add(sub);
    }
    return merged;
  }

  List<SubtitleTrackConfig> _buildSubtitleConfigs(
    List<SubtitleFile> subtitles,
  ) {
    return subtitles
        .map(
          (subtitle) => SubtitleTrackConfig(
            uri: subtitle.url,
            mimeType: subtitle.url.toLowerCase().endsWith('.vtt')
                ? 'text/vtt'
                : 'application/x-subrip',
            language: subtitle.lang ?? 'und',
          ),
        )
        .toList();
  }

  Future<void> _openResolvedStream(
    String playUrl,
    StreamResult stream,
    Map<String, String> headers, {
    required bool useVideoView,
    bool play = true,
  }) async {
    final sourceSessionId = state.sourceSessionId;
    if (!_isCurrentSourceSession(sourceSessionId)) return;
    _resolvedPlayUrl = playUrl;
    if (useVideoView) {
      if (!state.useExoPlayer) {
        await _player.pause();
        if (!_isCurrentSourceSession(sourceSessionId)) return;
      }
      _videoViewController?.setAutoPlay(play);

      String finalUrl = playUrl;
      if (finalUrl.contains('play.php') || finalUrl.contains('index.php')) {
        finalUrl = LocalProxyService.instance.getProxyUrl(
          finalUrl,
          headers: headers,
          forceM3u8Extension: true,
        );
        _resolvedPlayUrl = finalUrl;
      }

      if (Platform.isWindows) {
        final scheme = Uri.tryParse(finalUrl)?.scheme ?? '';
        final lowerUrl = finalUrl.toLowerCase();
        final hasAdaptiveExtension =
            lowerUrl.contains('.m3u8') ||
            lowerUrl.contains('.mpd') ||
            lowerUrl.contains('.ism/manifest');
        if (hasAdaptiveExtension &&
            scheme != 'http' &&
            scheme != 'https' &&
            scheme != 'file') {
          throw Exception(
            'Unsupported URL scheme "$scheme" for native adaptive player on Windows',
          );
        }
      }

      final subs = state.externalSubtitles;
      if (subs.isNotEmpty && _videoViewSupportsMergedExternalSubtitles) {
        _videoViewController!.openWithSubtitles(
          finalUrl,
          headers: headers,
          subtitles: _buildSubtitleConfigs(subs),
          drmKey: stream.drmKey,
          drmKid: stream.drmKid,
        );
      } else {
        _videoViewController!.open(
          finalUrl,
          headers: headers,
          drmKey: stream.drmKey,
          drmKid: stream.drmKid,
        );
      }
      final isLivePlayback = state.isLive || _detectResolvedLiveState(playUrl);
      state = state.copyWith(useExoPlayer: true, isSeekable: !isLivePlayback);
      _scheduleAutoSubtitleSelection();
      return;
    }

    if (state.useExoPlayer) {
      _videoViewController?.close();
    }

    _failedAudioTrackIds.clear();
    _lastKnownAudioTrackId = null;
    _audioFailoverLastTime = null;

    String mediaKitUrl = playUrl;
    final lowerPlayUrl = playUrl.toLowerCase();
    final isHlsUrl =
        lowerPlayUrl.contains('.m3u8') ||
        (lowerPlayUrl.contains('/hls/') && !lowerPlayUrl.startsWith('file'));
    final lowerHdrs = headers.map((k, v) => MapEntry(k.toLowerCase(), v));
    if (isHlsUrl && lowerHdrs.containsKey('cookie')) {
      final cookieNames = lowerHdrs['cookie']!
          .split(';')
          .map((c) => c.trim().split('=').first.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final proxyOptions = ProxyOptions(
        mirrorHosts: const [],
        keepCookies: cookieNames,
      );
      final simplified = await _buildSimplifiedMasterPlaylist(
        playUrl,
        headers,
        proxyOptions,
      );
      if (!_isCurrentSourceSession(sourceSessionId)) return;
      if (simplified != null) {
        mediaKitUrl = LocalProxyService.instance.serveM3u8(simplified);
      } else {
        mediaKitUrl = LocalProxyService.instance.getProxyUrl(
          playUrl,
          headers: headers,
          options: proxyOptions,
        );
      }
    }

    if (!_isCurrentSourceSession(sourceSessionId)) return;
    await _player.open(Media(mediaKitUrl, httpHeaders: headers), play: play);
    if (!_isCurrentSourceSession(sourceSessionId)) return;
    state = state.copyWith(useExoPlayer: false, isSeekable: true);
    unawaited(applyAnime4kShaders());
    _scheduleAutoSubtitleSelection();
  }

  String _anime4kApplied = '';

  Future<void> applyAnime4kShaders() async {
    if (_isDisposed) return;
    if (!anime4kAvailableOn(
      isNativePlatform:
          Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux ||
          Platform.isAndroid ||
          Platform.isIOS,
      usingAdaptiveBackend: state.useExoPlayer,
    )) {
      return;
    }
    final platform = _player.platform;
    if (platform is! NativePlayer) return;

    try {
      final settings = ref.read(playerSettingsProvider).asData?.value;
      final pipeline = await ref
          .read(anime4kShaderLibraryProvider)
          .pipeline(
            mode: (settings?.anime4kEnabled ?? false)
                ? (settings?.anime4kMode ?? Anime4kMode.off)
                : Anime4kMode.off,
            quality: settings?.anime4kQuality ?? Anime4kQuality.m,
            directory: settings?.anime4kShaderDirectory ?? '',
          );
      if (_isDisposed) return;

      String currentVo = '';
      if (!pipeline.isEmpty) {
        currentVo = (await platform.getProperty('current-vo')).trim();
        if (!anime4kGpuRendererSupportsShaders(currentVo)) {
          await platform.setProperty('glsl-shaders', '');
          _anime4kApplied = '';
          if (kDebugMode) {
            debugPrint(
              'Anime4K: GPU shader stage unavailable (vo="$currentVo")',
            );
          }
          return;
        }
      }

      await platform.setProperty('glsl-shaders', pipeline.value);
      final applied = await platform.getProperty('glsl-shaders');
      _anime4kApplied = applied.trim();
      if (pipeline.value.isNotEmpty && _anime4kApplied.isEmpty) {
        if (kDebugMode) {
          debugPrint('Anime4K: mpv did not accept the shader chain');
        }
        return;
      }

      if (!pipeline.isEmpty) {
        final gpuDumbMode = (await platform.getProperty('gpu-dumb-mode'))
            .trim()
            .toLowerCase();
        if (gpuDumbMode == 'yes') {
          await platform.setProperty('glsl-shaders', '');
          _anime4kApplied = '';
          if (kDebugMode) {
            debugPrint(
              'Anime4K: GPU shader stage unavailable '
              '(vo="$currentVo", gpu-dumb-mode="$gpuDumbMode")',
            );
          }
          return;
        }
      }

      if (kDebugMode) {
        debugPrint(
          'Anime4K: asked for ${pipeline.files.length} shaders, '
          'mpv holds "$_anime4kApplied"'
          '${pipeline.missing.isEmpty ? '' : ', missing ${pipeline.missing.join(", ")}'}',
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Anime4K shaders not applied: $e');
    }
  }

  Future<void> seekTo(Duration position, {bool fast = false}) async {
    if (!state.canSeek) return;
    _isNextEpisodeOverlayForced = false;
    final clamped = position < Duration.zero ? Duration.zero : position;
    if (state.useExoPlayer && _videoViewController != null) {
      _videoViewController!.seekTo(clamped.inMilliseconds, fast: fast);
      return;
    }
    await _player.seek(clamped);
  }

  Future<void> seekRelative(Duration amount, {bool fast = false}) async {
    if (!state.canSeek) return;
    final currentPosition = state.useExoPlayer
        ? Duration(milliseconds: _videoViewController?.position.value ?? 0)
        : _player.state.position;
    await seekTo(currentPosition + amount, fast: fast);
  }

  Future<void> play() async {
    final sourceSessionId = state.sourceSessionId;
    if (!_isCurrentSourceSession(sourceSessionId)) return;
    if (_shouldRefreshSignedUrl() && !_isReconnectingCurrentStream) {
      _pausedAt = null;
      await _triggerMidPlaybackReconnect(consumeRetryBudget: false);
      if (!_isCurrentSourceSession(sourceSessionId)) return;
      if (isPlaying) return;
    } else {
      _pausedAt = null;
    }
    if (state.useExoPlayer && _videoViewController != null) {
      _videoViewController!.play();
    } else {
      await _player.play();
    }
  }

  Future<void> pause() async {
    _pausedAt = DateTime.now();
    if (state.useExoPlayer && _videoViewController != null) {
      _videoViewController!.pause();
    } else {
      await _player.pause();
    }
  }

  bool _shouldRefreshSignedUrl() {
    final stream = state.currentStream;
    if (stream == null) return false;
    if (AppUtils.isLocalFile(stream.url)) return false;
    final token = stream.refreshUrl;
    if (token == null || token.isEmpty) return false;
    final pausedAt = _pausedAt;
    if (pausedAt == null) return false;
    return DateTime.now().difference(pausedAt) >=
        PlaybackRecoveryPolicy.signedUrlRefreshAfter;
  }

  bool get isPlaying {
    if (state.useExoPlayer && _videoViewController != null) {
      return _videoViewController!.playbackState.value ==
          VideoControllerPlaybackState.playing;
    }
    return _player.state.playing;
  }

  Future<void> togglePlayPause() async {
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> selectSubtitleTrack(String? id) async {
    if (state.useExoPlayer && _videoViewController != null) {
      if (id == null) {
        _videoViewController!.setShowSubtitle(false);
        if (_videoViewController!.overrideSubtitle.value != null) {
          _videoViewController!.setOverrideSubtitle(null);
        }
        return;
      }

      _videoViewController!.setShowSubtitle(true);
      _videoViewController!.setOverrideSubtitle(id);
      return;
    }

    if (id == null) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }

    if (id.startsWith('external:')) {
      final url = id.substring('external:'.length);
      final subtitle = state.externalSubtitles.firstWhereOrNull(
        (sub) => sub.url == url,
      );
      if (subtitle != null) {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(
            subtitle.url,
            title: subtitle.label,
            language: subtitle.lang,
          ),
        );
      }
      return;
    }

    final embeddedKey = id.startsWith('embedded:')
        ? id.substring('embedded:'.length)
        : id;
    final track = _findEmbeddedSubtitleTrack(embeddedKey);
    if (track != null) {
      await _player.setSubtitleTrack(track);
    }
  }

  SubtitleTrack? _findEmbeddedSubtitleTrack(String key) {
    final tracks = _player.state.tracks.subtitle;
    if (tracks.isEmpty) return null;
    final byId = tracks.firstWhereOrNull((t) => t.id == key);
    if (byId != null) return byId;
    final lowerKey = key.toLowerCase();
    return tracks.firstWhereOrNull((t) {
      final lang = (t.language ?? '').toLowerCase();
      final title = (t.title ?? '').toLowerCase();
      return lang == lowerKey || title == lowerKey || title.contains(lowerKey);
    });
  }

  void _scheduleAutoSubtitleSelection() {
    if (state.useExoPlayer) {
      Future.delayed(const Duration(milliseconds: 800), () {
        unawaited(_autoSelectFirstSubtitleIfNeeded());
      });
      return;
    }
    StreamSubscription<dynamic>? sub;
    sub = _player.stream.track.listen((_) {
      sub?.cancel();
      unawaited(_autoSelectFirstSubtitleIfNeeded());
    });
    Future.delayed(const Duration(milliseconds: 2000), () {
      sub?.cancel();
      unawaited(_autoSelectFirstSubtitleIfNeeded());
    });
  }

  Future<void> _autoSelectFirstSubtitleIfNeeded() async {
    final currentId = state.useExoPlayer
        ? _videoViewController?.overrideSubtitle.value
        : _player.state.track.subtitle.id;
    final hasSelection =
        currentId != null && currentId != 'no' && currentId != 'auto';
    if (hasSelection) return;

    final external = state.externalSubtitles;
    if (external.isNotEmpty) {
      await selectSubtitleTrack('external:${external.first.url}');
      return;
    }

    if (!state.useExoPlayer) {
      final embedded = _player.state.tracks.subtitle;
      if (embedded.isNotEmpty) {
        await selectSubtitleTrack(embedded.first.id);
      }
    }
  }

  Future<bool> _isStreamCandidateHealthy(StreamResult stream) async {
    if (AppUtils.isLocalFile(stream.url)) return true;

    final uri = Uri.parse(stream.url);
    final headers = <String, String>{...?stream.headers};

    try {
      final resp = await http
          .head(uri, headers: headers)
          .timeout(const Duration(seconds: 3));
      final contentType = resp.headers['content-type'];
      if (contentType != null &&
          contentType.trim().isNotEmpty &&
          isLikelyPlayableHttpResponse(
            uri: uri,
            statusCode: resp.statusCode,
            contentType: contentType,
          )) {
        return true;
      }
    } catch (_) {}

    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers.addAll(headers);
      request.headers.putIfAbsent('Range', () => 'bytes=0-511');
      final resp = await client
          .send(request)
          .timeout(const Duration(seconds: 3));
      final prefix = <int>[];
      await for (final chunk in resp.stream) {
        final remaining = 512 - prefix.length;
        if (remaining > 0) prefix.addAll(chunk.take(remaining));
        break;
      }
      return isLikelyPlayableHttpResponse(
        uri: uri,
        statusCode: resp.statusCode,
        contentType: resp.headers['content-type'],
        bodyPrefix: prefix,
      );
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  Future<void> loadStreamAtIndex(
    int index, {
    int? sourceSessionId,
    bool manualSelection = false,
  }) async {
    sourceSessionId ??= state.sourceSessionId;
    if (_isDisposed) return;
    if (index < 0 || index >= state.streams.length) return;
    if (!_isCurrentSourceSession(sourceSessionId)) return;

    final stream = state.streams[index];
    final subtitles = _effectiveExternalSubtitles(stream.subtitles);
    _markSourceAttempt(
      index,
      manualSelection
          ? SourceAttemptStatus.selected
          : SourceAttemptStatus.trying,
    );
    _manualSelectionPending = manualSelection;

    state = state.copyWith(
      currentStreamIndex: index,
      currentStream: stream,
      externalSubtitles: subtitles,
      isLive:
          _item.contentType == MultimediaContentType.livestream ||
          _isLiveStream(stream.url),
    );

    if (manualSelection && _hasConfirmedPlaybackFrame) {
      _enterRuntimePhase(kind: PlaybackUiPhaseKind.switchingSource);
    } else {
      _enterStartupPhase(kind: PlaybackUiPhaseKind.openingSource);
    }

    try {
      final playUrl = await _resolveStreamUrl(stream);
      if (playUrl == null) throw Exception('Failed to resolve stream URL');
      if (!_isCurrentSourceSession(sourceSessionId)) return;

      final resolvedIsLive = _detectResolvedLiveState(playUrl);
      final useVideoView = _canUseVideoViewForStream(
        playUrl,
        stream,
        isLive: resolvedIsLive,
      );
      if (!_isCurrentSourceSession(sourceSessionId)) return;
      state = state.copyWith(isLive: resolvedIsLive, isSeekable: !useVideoView);
      if (state.useExoPlayer != useVideoView && _hasConfirmedPlaybackFrame) {
        _enterRuntimePhase(kind: PlaybackUiPhaseKind.switchingEngine);
      }

      final headers = _buildPlaybackHeaders(stream);
      await _applyPlaybackProperties(
        headers,
        stream,
        useVideoView: useVideoView,
      );
      if (!_isCurrentSourceSession(sourceSessionId)) return;

      var holdForResume = false;
      final opened = await PlaybackResume.openWhenReady(
        isActive: () => _isCurrentSourceSession(sourceSessionId!),
        resolvePosition: () => _resolveResumePosition(isLive: resolvedIsLive),
        open: (savedPos) async {
          holdForResume = PlaybackResume.shouldHoldUntilSeeked(savedPos);
          if (holdForResume) _pendingResumeSeekPosition = savedPos;
          await _openResolvedStream(
            playUrl,
            stream,
            headers,
            useVideoView: useVideoView,
            play: !holdForResume,
          );
        },
      );
      if (!opened) return;
      if (!_hasConfirmedPlaybackFrame) {
        _enterStartupPhase(kind: PlaybackUiPhaseKind.bufferingInitial);
      }
      if (holdForResume) {
        await _flushPendingResumeSeek();
      }
    } catch (e) {
      if (!_isCurrentSourceSession(sourceSessionId)) return;
      _markSourceAttempt(index, SourceAttemptStatus.failed);
      if (manualSelection) {
        revertToPreviousStream(
          _playerText(
            english: 'Selected source is not playable. Reverting back to previous source.',
            arabic: 'المصدر المحدد غير قابل للتشغيل. جارٍ الرجوع إلى المصدر السابق.',
          ),
        );
        return;
      }
      unawaited(retryNextStream(sourceSessionId: sourceSessionId));
    }
  }

  Future<void> goLive() async {
    if (!state.isLive || state.currentStream == null) return;
    final dur = state.useExoPlayer
        ? Duration(
            milliseconds: _videoViewController?.mediaInfo.value?.duration ?? 0,
          )
        : _player.state.duration;
    if (dur > Duration.zero) {
      await seekTo(dur);
    } else {
      _enterRuntimePhase(kind: PlaybackUiPhaseKind.reconnectingLive);
      unawaited(changeStream(state.currentStream!, resetPosition: true));
    }
  }

  Future<void> changeStream(
    StreamResult stream, {
    bool isRevert = false,
    bool resetPosition = false,
    bool manualSelection = false,
  }) async {
    final matchingIndex = state.streams.indexWhere(
      (candidate) =>
          candidate.url == stream.url && candidate.source == stream.source,
    );
    if (!isRevert) {
      state = state.copyWith(
        previousStream: state.currentStream,
        currentStreamIndex: matchingIndex == -1
            ? state.currentStreamIndex
            : matchingIndex,
      );
    }
    if (manualSelection && !isRevert) _manualSelectionPending = true;

    final oldPos = state.useExoPlayer
        ? Duration(milliseconds: _videoViewController?.position.value ?? 0)
        : _player.state.position;
    final holdPosition = oldPos > Duration.zero && !resetPosition;

    _enterRuntimePhase(kind: PlaybackUiPhaseKind.switchingSource);

    try {
      final playUrl = await _resolveStreamUrl(stream);
      if (playUrl == null) throw Exception('Failed to resolve stream URL');
      final subtitles = _effectiveExternalSubtitles(stream.subtitles);

      final resolvedIsLive = _detectResolvedLiveState(playUrl);
      final useVideoView = _canUseVideoViewForStream(
        playUrl,
        stream,
        isLive: resolvedIsLive,
      );
      if (state.useExoPlayer != useVideoView && _hasConfirmedPlaybackFrame) {
        _enterRuntimePhase(kind: PlaybackUiPhaseKind.switchingEngine);
      }
      state = state.copyWith(
        currentStream: stream,
        externalSubtitles: subtitles,
        isLive: resolvedIsLive,
        isSeekable: !useVideoView,
      );

      final headers = _buildPlaybackHeaders(stream);
      await _applyPlaybackProperties(
        headers,
        stream,
        useVideoView: useVideoView,
      );
      await _openResolvedStream(
        playUrl,
        stream,
        headers,
        useVideoView: useVideoView,
        play: !holdPosition,
      );

      if (holdPosition) {
        await _seekThenPlay(oldPos.inMilliseconds);
      } else if (resetPosition) {
        await seekTo(Duration.zero, fast: true);
      }
    } catch (e) {
      _manualSelectionPending = false;
      if (isRevert) {
        state = state.copyWith(
          errorMessage: _playerText(
            english: 'Revert failed: $e',
            arabic: 'فشل الرجوع: $e',
          ),
        );
      } else {
        revertToPreviousStream(
          _playerText(
            english: 'Could not switch to selected source. Reverting back to previous source.',
            arabic: 'تعذر التبديل إلى المصدر المحدد. جارٍ الرجوع إلى المصدر السابق.',
          ),
        );
      }
    }
  }

  Future<void> retryNextStream({int? sourceSessionId}) async {
    _resetBufferWatchdog();
    _resetMidPlaybackReconnect();
    if (sourceSessionId != null && !_isCurrentSourceSession(sourceSessionId)) {
      return;
    }

    int nextIndex = state.currentStreamIndex + 1;
    while (nextIndex < state.streams.length) {
      final attempt = state.sourceAttempts.firstWhereOrNull(
        (e) => e.index == nextIndex,
      );
      if (attempt == null || attempt.status != SourceAttemptStatus.failed) break;
      nextIndex++;
    }

    if (nextIndex < state.streams.length) {
      final nextAttempt = state.sourceAttempts.firstWhereOrNull(
        (e) => e.index == nextIndex,
      );
      final alreadyHealthChecked =
          nextAttempt?.status == SourceAttemptStatus.trying;
      final hasNextChecked = state.sourceAttempts.any(
        (e) => e.index > nextIndex && e.status != SourceAttemptStatus.pending,
      );
      int targetIndex = nextIndex;

      if (alreadyHealthChecked) {
        _enterStartupPhase(kind: PlaybackUiPhaseKind.checkingSources);
      } else if (!hasNextChecked && state.streams.length > nextIndex + 1) {
        final checkCount = (state.streams.length - nextIndex) > 3
            ? 3
            : (state.streams.length - nextIndex);
        final batchIndices = {
          for (int i = 0; i < checkCount; i++)
            (nextIndex + i) % state.streams.length,
        };
        final updatedAttempts = state.sourceAttempts
            .map(
              (e) => batchIndices.contains(e.index)
                  ? e.copyWith(status: SourceAttemptStatus.trying)
                  : e,
            )
            .toList();
        state = state.copyWith(sourceAttempts: updatedAttempts);
        _enterStartupPhase(kind: PlaybackUiPhaseKind.checkingSources);

        targetIndex = await _findFirstWorkingStream(
          state.streams,
          startIndex: nextIndex,
          limit: checkCount,
          sourceSessionId: sourceSessionId,
        );
      } else {
        _enterStartupPhase(kind: PlaybackUiPhaseKind.checkingSources);
      }

      _markSourceAttempt(targetIndex, SourceAttemptStatus.trying);
      unawaited(
        loadStreamAtIndex(targetIndex, sourceSessionId: sourceSessionId),
      );
    } else {
      _enterAllSourcesFailedPhase();
    }
  }

  void revertToPreviousStream(String message) {
    if (state.previousStream == null) {
      retryNextStream(sourceSessionId: state.sourceSessionId);
      return;
    }
    _revertMessage = message;
    changeStream(state.previousStream!, isRevert: true);
  }

  String? _revertMessage;
  String? consumeRevertMessage() {
    final msg = _revertMessage;
    _revertMessage = null;
    return msg;
  }

  void _resetPerEpisodeState() {
    _hasMarkedWatched = false;
    _lastKnownPlaybackPositionMs = 0;
    _lastKnownPlaybackDurationMs = 0;
    _lastSavedPosition = Duration.zero;
    _pendingResumeSeekPosition = null;
    _isApplyingPendingResumeSeek = false;
    if (state.skipSegments.isNotEmpty) {
      state = state.copyWith(skipSegments: const []);
    }
    unawaited(setSubtitleDelay(0.0));
  }

  Future<void> _recordEpisodeOpened(Episode episode) async {
    final pId =
        _item.provider ??
        ref.read(activeProviderProvider)?.packageName ??
        'Unknown';
    final itemToSave = _item.copyWith(provider: pId);
    await ref
        .read(watchHistoryProvider.notifier)
        .recordOpened(
          itemToSave,
          lastEpisodeUrl: episode.url,
          season: episode.season,
          episode: episode.episode,
          episodeTitle: episodeTitleForStorage(
            episode: episode.episode,
            title: episode.name,
            isFinal: episode.isFinal,
            serverName: episode.serverName,
          ),
          episodeServerName: episode.serverName,
          episodePosterUrl: _episodeArtwork(episode),
        );
  }

  void _warmNextEpisodeSources(Episode next) {
    if (_isDisposed) return;
    try {
      final settings = ref.read(playerSettingsProvider).asData?.value;
      if (settings != null && !settings.prefetchNextEpisode) return;

      final behaviour = settings?.fillerBehaviour ?? FillerBehaviour.note;
      final target = behaviour == FillerBehaviour.skip && next.isFiller
          ? (nextStoryEpisodeOrNull ?? next)
          : next;
      if (target.url.trim().isEmpty) return;

      final provider = ref.read(activeProviderProvider);
      if (provider == null) return;
      ref.read(streamSourcePrefetchProvider).warm(provider, target.url);
    } catch (_) {}
  }

  Future<void> playNextEpisode({StreamResult? selectedSource}) async {
    final behaviour =
        ref.read(playerSettingsProvider).asData?.value.fillerBehaviour ??
        FillerBehaviour.note;
    final skipsFiller = behaviour == FillerBehaviour.skip;
    final nextEpisode =
        (skipsFiller && (this.nextEpisode?.isFiller ?? false)
            ? nextStoryEpisodeOrNull
            : null) ??
        this.nextEpisode;
    if (nextEpisode == null) return;

    if (nextEpisode.url != this.nextEpisode?.url) selectedSource = null;

    final downloadService = ref.read(downloadServiceProvider);
    final localFile = await downloadService.getDownloadedFile(
      _item,
      episode: nextEpisode,
    );

    final bool isLocal = localFile != null;
    final bool useDirectSelectedSource =
        !isLocal &&
        selectedSource != null &&
        !selectedSource.requiresResolution;
    final String finalUrl =
        localFile?.path ??
        ((selectedSource?.requiresResolution ?? false)
            ? selectedSource!.url
            : nextEpisode.url);

    saveProgress();
    await pause();

    _suppressNextEpisodeDetection = true;
    _hasConfirmedPlaybackFrame = false;
    _videoUrl = finalUrl;
    _episode = nextEpisode;
    _progressUrl = nextEpisode.url;
    await _recordEpisodeOpened(nextEpisode);
    _userAddedExternalSubtitles.clear();
    _resetPerEpisodeState();
    _maybeFetchSkipSegments();

    state = state.copyWith(
      playerTitle: _titleWithEpisode(nextEpisode),
      activeEpisodeUrl: nextEpisode.url,
      showNextEpisodeOverlay: false,
    );

    if (useDirectSelectedSource) {
      final sourceSessionId = _beginSourceSession(resetAttempts: true);
      state = state.copyWith(
        streams: <StreamResult>[selectedSource],
        currentStreamIndex: 0,
      );
      _setSourceAttemptsFromStreams(<StreamResult>[selectedSource]);
      await loadStreamAtIndex(0, sourceSessionId: sourceSessionId);
      return;
    }

    await _initStream(
      requestedPhaseKind: PlaybackUiPhaseKind.loadingNextEpisode,
    );
  }

  void dismissNextEpisodeOverlay() {
    _userDismissedOverlay = true;
    state = state.copyWith(showNextEpisodeOverlay: false);
  }

  void openEpisodeList() {
    state = state.copyWith(showEpisodeList: true);
  }

  void closeEpisodeList() {
    if (!state.showEpisodeList) return;
    state = state.copyWith(showEpisodeList: false);
  }

  Future<void> loadEpisode(
    Episode episode, {
    StreamResult? selectedSource,
  }) async {
    if (state.isLoading) return;
    state = state.copyWith(showEpisodeList: false);

    saveProgress();

    final downloadService = ref.read(downloadServiceProvider);
    final localFile = await downloadService.getDownloadedFile(
      _item,
      episode: episode,
    );

    final bool isLocal = localFile != null;
    final bool useDirectSelectedSource =
        !isLocal &&
        selectedSource != null &&
        !selectedSource.requiresResolution;
    final String finalUrl =
        localFile?.path ??
        ((selectedSource?.requiresResolution ?? false)
            ? selectedSource!.url
            : episode.url);

    await pause();

    _episode = episode;
    _videoUrl = finalUrl;
    _progressUrl = episode.url;
    await _recordEpisodeOpened(episode);
    _hasConfirmedPlaybackFrame = false;
    _suppressNextEpisodeDetection = true;
    _userAddedExternalSubtitles.clear();
    _resetPerEpisodeState();
    _maybeFetchSkipSegments();

    state = state.copyWith(
      playerTitle: _titleWithEpisode(episode),
      activeEpisodeUrl: episode.url,
      showNextEpisodeOverlay: false,
    );

    if (useDirectSelectedSource) {
      final sourceSessionId = _beginSourceSession(resetAttempts: true);
      state = state.copyWith(
        streams: <StreamResult>[selectedSource],
        currentStreamIndex: 0,
      );
      _setSourceAttemptsFromStreams(<StreamResult>[selectedSource]);
      await loadStreamAtIndex(0, sourceSessionId: sourceSessionId);
      return;
    }

    await _initStream(
      requestedPhaseKind: PlaybackUiPhaseKind.loadingNextEpisode,
    );
  }

  void saveProgress() {
    try {
      int pos;
      int dur;
      if (state.useExoPlayer && _videoViewController != null) {
        pos = _videoViewController!.position.value;
        dur = _videoViewController!.mediaInfo.value?.duration ?? 0;
      } else {
        pos = _player.state.position.inMilliseconds;
        dur = _player.state.duration.inMilliseconds;
      }

      if (dur < 30000 && _lastKnownPlaybackDurationMs >= 30000) {
        dur = _lastKnownPlaybackDurationMs;
        if (pos <= 0 && _lastKnownPlaybackPositionMs > 0) {
          pos = _lastKnownPlaybackPositionMs;
        }
      }
      if (pos > 0) _lastKnownPlaybackPositionMs = pos;
      if (dur >= 30000) _lastKnownPlaybackDurationMs = dur;
      final isLivestream =
          _item.contentType == MultimediaContentType.livestream;

      if (isLivestream) {
        final pId =
            _item.provider ??
            ref.read(activeProviderProvider)?.packageName ??
            'Unknown';
        final itemToSave = _item.copyWith(provider: pId);
        ref
            .read(continueWatchingProvider.notifier)
            .saveProgress(
              itemToSave,
              0,
              0,
              lastStreamUrl: null,
              lastEpisodeUrl: null,
            );
        return;
      }

      if (dur < 30000) return;

      final double progressPercent = (pos / dur) * 100;
      final bool isSeries =
          (_item.contentType == MultimediaContentType.series ||
          _item.contentType == MultimediaContentType.anime);
      final currentEpisode = _resolveCurrentEpisode();
      if (progressPercent >= 90) {
        if (!_hasMarkedWatched) {
          if (isSeries && currentEpisode != null) {
            unawaited(
              ref
                  .read(episodeWatchRepositoryProvider)
                  .setWatched(_item.url, currentEpisode, true)
                  .catchError((Object error) {
                    talker.error('Failed to save local watched state', error);
                  }),
            );
          }
          _hasMarkedWatched = true;
        }

        final continueNotifier = ref.read(continueWatchingProvider.notifier);
        final pId =
            _item.provider ??
            ref.read(activeProviderProvider)?.packageName ??
            'Unknown';
        final itemToSave = _item.copyWith(provider: pId);

        if (!isSeries) {
          continueNotifier.remove(_item.url);
          return;
        } else if (currentEpisode != null) {
          List<Episode> episodes = _item.episodes ?? const <Episode>[];
          if (currentEpisode.dubStatus != DubStatus.none) {
            episodes = episodes
                .where((e) => e.dubStatus == currentEpisode.dubStatus)
                .toList();
          }
          final currentIndex = episodes.indexOf(currentEpisode);
          if (currentIndex != -1 && currentIndex < episodes.length - 1) {
            final nextEpisode = episodes[currentIndex + 1];
            continueNotifier.saveProgress(
              itemToSave,
              0,
              0,
              lastStreamUrl: null,
              lastEpisodeUrl: nextEpisode.url,
              season: nextEpisode.season,
              episode: nextEpisode.episode,
              episodeTitle: episodeTitleForStorage(
                episode: nextEpisode.episode,
                title: nextEpisode.name,
                isFinal: nextEpisode.isFinal,
                serverName: nextEpisode.serverName,
              ),
              episodeServerName: nextEpisode.serverName,
              episodePosterUrl: _episodeArtwork(nextEpisode),
            );
            return;
          } else {
            continueNotifier.remove(_item.url);
            return;
          }
        }
      }

      if (progressPercent > 5 || isSeries) {
        final pId =
            _item.provider ??
            ref.read(activeProviderProvider)?.packageName ??
            'Unknown';
        final itemToSave = _item.copyWith(provider: pId);
        ref
            .read(continueWatchingProvider.notifier)
            .saveProgress(
              itemToSave,
              pos,
              dur,
              lastStreamUrl: state.currentStream?.url,
              lastEpisodeUrl: currentEpisode?.url ?? _currentProgressUrl,
              season: currentEpisode?.season,
              episode: currentEpisode?.episode,
              episodeTitle: currentEpisode == null
                  ? null
                  : episodeTitleForStorage(
                      episode: currentEpisode.episode,
                      title: currentEpisode.name,
                      isFinal: currentEpisode.isFinal,
                      serverName: currentEpisode.serverName,
                    ),
              episodeServerName: currentEpisode?.serverName,
              episodePosterUrl: _episodeArtwork(currentEpisode),
            );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('History save failed: $e');
    }
  }

  void disposeController({Player? player}) {
    if (player != null && _isInitialized && !identical(_player, player)) return;
    if (_isDisposed) return;
    _isDisposed = true;
    final closingSession = ++_sourceSessionSerial;
    _pendingResumeSeekPosition = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _bufferWatchdogTimer?.cancel();
    _bufferWatchdogTimer = null;
    _bufferingHideTimer?.cancel();
    _bufferingHideTimer = null;
    _stallRecoveryGuardTimer?.cancel();
    _stallRecoveryGuardTimer = null;

    _errorSub?.cancel();
    _playingSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _bufferingSub?.cancel();
    _completedSub?.cancel();
    _rateSub?.cancel();
    _logSub?.cancel();
    _trackSub?.cancel();
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _midPlaybackRetryTimer?.cancel();
    _midPlaybackRetryTimer = null;

    unawaited(_cleanupSubtitleTempFiles());

    if (_isInitialized) saveProgress();
    Future.microtask(() {
      if (ref.mounted &&
          _isDisposed &&
          _sourceSessionSerial == closingSession) {
        state = const PlayerState();
      }
    });
  }

  Future<void> _cleanupSubtitleTempFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (!await tempDir.exists()) return;
      await for (final entity in tempDir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('sub_') || name.startsWith('temp_sub_')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[PlayerController] subtitle cleanup: $e');
    }
  }

  Future<int> _findFirstWorkingStream(
    List<StreamResult> streams, {
    required int startIndex,
    required int limit,
    int? sourceSessionId,
  }) async {
    if (streams.isEmpty) return 0;
    final int start = startIndex.clamp(0, streams.length - 1);
    final candidates = <int>[];
    for (int i = 0; i < limit; i++) {
      final idx = (start + i) % streams.length;
      if (!candidates.contains(idx)) candidates.add(idx);
    }

    if (candidates.length <= 1) return start;

    try {
      if (sourceSessionId != null &&
          !_isCurrentSourceSession(sourceSessionId)) {
        return start;
      }
      final completer = Completer<int>();
      final results = <int, bool>{};

      for (final idx in candidates) {
        unawaited(
          _isStreamCandidateHealthy(streams[idx])
              .then((isHealthy) {
                if (completer.isCompleted) return;
                if (!isHealthy) {
                  _markSourceAttempt(idx, SourceAttemptStatus.failed);
                }
                results[idx] = isHealthy;
                for (final c in candidates) {
                  if (!results.containsKey(c)) break;
                  if (results[c]!) {
                    completer.complete(c);
                    return;
                  }
                }
                if (results.length == candidates.length &&
                    !completer.isCompleted) {
                  completer.complete(start);
                }
              })
              .catchError((_) {
                if (completer.isCompleted) return;
                results[idx] = false;
                _markSourceAttempt(idx, SourceAttemptStatus.failed);
                if (results.length == candidates.length) {
                  completer.complete(start);
                }
              }),
        );
      }

      final winner = await completer.future;
      if (sourceSessionId != null &&
          !_isCurrentSourceSession(sourceSessionId)) {
        return start;
      }
      return winner;
    } catch (e) {
      if (kDebugMode) debugPrint('Parallel check failed: $e');
    }

    return start;
  }

  Future<String?> _resolveStreamUrl(
    StreamResult stream, {
    bool forceRefresh = false,
  }) async {
    final token = stream.refreshUrl;
    final shouldRefresh = forceRefresh && token != null && token.isNotEmpty;
    if (shouldRefresh) {
      final provider = _resolveProvider();
      if (provider != null) {
        final fresh = await provider.loadStreams(token);
        if (fresh.isEmpty) {
          throw StateError('Failed to re-resolve stream URL');
        }
        final resolved = fresh.first;
        final merged = stream.copyWith(
          url: resolved.url,
          headers: resolved.headers,
          quality: resolved.quality,
          refreshUrl: token,
        );
        _replaceCurrentStream(merged);
        return AppUtils.normalizeUrl(merged.url);
      }
    }
    return AppUtils.normalizeUrl(stream.url);
  }

  void _replaceCurrentStream(StreamResult updated) {
    final streams = List<StreamResult>.from(state.streams);
    final index = state.currentStreamIndex;
    if (index >= 0 && index < streams.length) streams[index] = updated;
    state = state.copyWith(streams: streams, currentStream: updated);
  }

  Future<void> _applyPlaybackProperties(
    Map<String, String> headers,
    StreamResult stream, {
    required bool useVideoView,
  }) async {
    if (_player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      final lowerHeaders = headers.map((k, v) => MapEntry(k.toLowerCase(), v));

      if (lowerHeaders.isNotEmpty) {
        final List<String> headerFields = [];
        lowerHeaders.forEach((key, value) {
          headerFields.add('$key: $value');
        });
        if (headerFields.isNotEmpty) {
          final fields = '${headerFields.join('\r\n')}\r\n';
          await native.setProperty('http-header-fields', fields);
        }
      }

      if (lowerHeaders.containsKey('user-agent')) {
        await native.setProperty('user-agent', lowerHeaders['user-agent']!);
      }
      if (lowerHeaders.containsKey('referer')) {
        await native.setProperty('referrer', lowerHeaders['referer']!);
      }

      final settings = ref.read(playerSettingsProvider).asData?.value;
      if (_forceSoftwareDecode) {
        await native.setProperty('hwdec', 'no');
      } else if (settings?.hardwareDecoding ?? true) {
        await native.setProperty(
          'hwdec',
          Platform.isWindows ? 'auto-safe' : 'auto',
        );
      } else {
        await native.setProperty('hwdec', 'no');
      }

      await native.setProperty('tls-verify', 'no');
      await native.setProperty('cache', 'yes');

      final demuxerLavfOpts = <String>[];
      if (lowerHeaders.containsKey('cookie')) {
        demuxerLavfOpts.add('headers=Cookie: ${lowerHeaders['cookie']!}\r\n');
      }

      final isLivePattern =
          _isLiveStream(stream.url) ||
          _item.contentType == MultimediaContentType.livestream;
      if (isLivePattern) {
        await native.setProperty('demuxer-readahead-secs', '8');
        await native.setProperty('cache-secs', '8');
        await native.setProperty('cache', 'yes');
        await native.setProperty('cache-pause-initial', 'yes');
        await native.setProperty('cache-pause-wait', '2');
        await native.setProperty('network-timeout', '30');
        await native.setProperty('tls-verify', 'no');
        await native.setProperty(
          'stream-lavf-o',
          'reconnect_on_network_error=1,reconnect_delay_max=5,reconnect_on_eof=1,reconnect_streamed=1',
        );
        demuxerLavfOpts.add('seg_max_retry=5');
        await native.setProperty('framedrop', 'decoder');
        await native.setProperty('hr-seek-framedrop', 'yes');
        await native.setProperty('hwdec', 'auto-safe');
        await native.setProperty('vd-lavc-skiploopfilter', 'nonkey');
        await native.setProperty('vd-lavc-skipframe', 'nonref');
      } else {
        final settings = ref.read(playerSettingsProvider).asData?.value;
        final readahead = settings?.readaheadSeconds ?? 180;
        await native.setProperty('demuxer-readahead-secs', '$readahead');
        await native.setProperty('cache-secs', '$readahead');
        await native.setProperty('cache', 'yes');
        await native.setProperty('cache-pause', 'yes');
        await native.setProperty('cache-pause-wait', '2');
        await native.setProperty('network-timeout', '30');
        await native.setProperty(
          'stream-lavf-o',
          'seekable=1,icy=0,reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=10',
        );
        await native.setProperty('force-seekable', 'yes');
        await native.setProperty('hls-bitrate', 'max');
        demuxerLavfOpts.add('allowed_extensions=ALL');
        demuxerLavfOpts.add('icy=0');

        final isHlsStream =
            stream.url.toLowerCase().contains('.m3u8') ||
            stream.url.toLowerCase().contains('/hls/');
        if (isHlsStream) {
          await native.setProperty('demuxer-lavf-probesize', '5242880');
          await native.setProperty('demuxer-lavf-analyzeduration', '2');
        } else {
          await native.setProperty('demuxer-lavf-probesize', '33554432');
          await native.setProperty('demuxer-lavf-analyzeduration', '30');
        }
      }

      final profile = ref.read(deviceProfileProvider).asData?.value;
      final isDashStream = _isDashStreamUrl(stream.url);
      String cacheSize = '192MiB';
      if (profile != null) {
        if (profile.isTv) {
          cacheSize = '128MiB';
        } else if (profile.isDesktopOS) {
          cacheSize = isDashStream ? '256MiB' : '512MiB';
        } else if (profile.isTablet) {
          cacheSize = '256MiB';
        }
      }

      await native.setProperty('demuxer-max-bytes', cacheSize);
      final backCacheSize = profile?.isTv == true
          ? '64MiB'
          : profile?.isDesktopOS == true
          ? '128MiB'
          : profile?.isTablet == true
          ? '96MiB'
          : '64MiB';
      await native.setProperty('demuxer-max-back-bytes', backCacheSize);

      String? keyHex = stream.drmKey;
      if (keyHex == null && stream.licenseUrl != null) {
        final extractedKeys = await _extractKeysFromLicenseUrl(
          stream.licenseUrl!,
          headers: stream.headers,
        );
        if (extractedKeys != null) keyHex = extractedKeys['key'];
      }

      if (keyHex != null && !useVideoView) {
        demuxerLavfOpts.add('cenc_decryption_key=$keyHex');
      }

      if (demuxerLavfOpts.isNotEmpty) {
        await native.setProperty('demuxer-lavf-o', demuxerLavfOpts.join(','));
      }

      try {
        final tempDir = await getTemporaryDirectory();
        final cookieFile = File(p.join(tempDir.path, 'mpv_cookies.txt'));
        if (!await cookieFile.exists()) await cookieFile.create();
        await native.setProperty('cookies-file', cookieFile.path);
        await native.setProperty('cache-dir', tempDir.path);
      } catch (_) {}

      await native.setProperty('sub-visibility', 'no');
    }
  }

  Future<String?> _buildSimplifiedMasterPlaylist(
    String masterUrl,
    Map<String, String> headers,
    ProxyOptions proxyOptions,
  ) async {
    try {
      final response = await http.get(Uri.parse(masterUrl), headers: headers);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;

      final baseUri = Uri.parse(masterUrl);
      final lines = response.body.split('\n');
      final langHint = baseUri.queryParameters['lang']?.toLowerCase();
      final allAudio = <(String line, int score)>[];
      for (final line in lines) {
        final t = line.trim();
        if (!t.startsWith('#EXT-X-MEDIA:') || !t.contains('TYPE=AUDIO')) {
          continue;
        }
        int score = 0;
        if (t.contains('DEFAULT=YES')) score += 2;
        if (t.contains('AUTOSELECT=YES')) score += 1;
        if (langHint != null) {
          final m = RegExp(
            r'LANGUAGE="([^"]*)"',
            caseSensitive: false,
          ).firstMatch(t);
          if (m != null) {
            final lang = m.group(1)!.toLowerCase();
            if (lang.startsWith(langHint) || langHint.startsWith(lang)) {
              score += 4;
            }
          }
        }
        allAudio.add((t, score));
      }

      allAudio.sort((a, b) => b.$2.compareTo(a.$2));
      final kept = allAudio;
      final result = <String>[];
      int audioEmitted = 0;
      for (final line in lines) {
        final t = line.trim();

        if (t.startsWith('#EXT-X-MEDIA:') && t.contains('TYPE=AUDIO')) {
          if (audioEmitted < kept.length) {
            var out = kept[audioEmitted].$1.replaceAllMapped(
              RegExp(r'URI="([^"]+)"'),
              (m) {
                final resolved = baseUri.resolve(m.group(1)!).toString();
                return 'URI="${LocalProxyService.instance.getProxyUrl(resolved, headers: headers, options: proxyOptions)}"';
              },
            );
            if (audioEmitted == 0) {
              out = out.contains('DEFAULT=')
                  ? out.replaceFirst(RegExp(r'DEFAULT=\w+'), 'DEFAULT=YES')
                  : out.replaceFirst(
                      '#EXT-X-MEDIA:',
                      '#EXT-X-MEDIA:DEFAULT=YES,',
                    );
            } else {
              out = out.replaceFirst(RegExp(r'DEFAULT=YES'), 'DEFAULT=NO');
            }
            result.add(out);
            audioEmitted++;
          }
          continue;
        }

        if (t.isNotEmpty && !t.startsWith('#')) {
          final resolved = baseUri.resolve(t).toString();
          result.add(
            LocalProxyService.instance.getProxyUrl(
              resolved,
              headers: headers,
              options: proxyOptions,
            ),
          );
          continue;
        }

        result.add(line);
      }
      return result.join('\n');
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>?> _extractKeysFromLicenseUrl(
    String licenseUrl, {
    Map<String, String>? headers,
  }) async {
    try {
      final response = await http.get(Uri.parse(licenseUrl), headers: headers);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final keys = body['keys'] as List<dynamic>?;
      if (keys == null || keys.isEmpty) return null;

      for (final entry in keys) {
        final kid = entry['kid'] as String?;
        final k = entry['k'] as String?;
        if (kid == null || k == null) continue;
        final kidHex = _base64UrlToHex(kid);
        final keyHex = _base64UrlToHex(k);
        if (kidHex != null && keyHex != null) {
          return {'kid': kidHex, 'key': keyHex};
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String? _base64UrlToHex(String base64url) {
    try {
      String padded = base64url;
      final rem = padded.length % 4;
      if (rem == 2) padded += '==';
      if (rem == 3) padded += '=';
      final bytes = base64Url.decode(padded);
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    } catch (_) {
      return null;
    }
  }

  bool _isLiveStream(String url) {
    if (url.isEmpty) return false;
    if (_item.contentType == MultimediaContentType.livestream) return true;
    final lower = url.toLowerCase();
    if (lower.startsWith('/')) return false;
    if (lower.startsWith('rtmp://') ||
        lower.startsWith('rtsp://') ||
        lower.startsWith('mms://') ||
        lower.startsWith('udp://') ||
        lower.startsWith('rtp://')) {
      return true;
    }
    if (lower.contains('/live/') ||
        lower.contains('/iptv/') ||
        lower.contains('stream.m3u8') ||
        lower.contains('chunklist')) {
      return true;
    }
    if (lower.contains('type=m3u8') || lower.contains('output=m3u8')) {
      return true;
    }
    return false;
  }

  Future<void> _safeSeekTo(int position) async {
    final sourceSessionId = state.sourceSessionId;
    if (position <= 0 || !_isCurrentSourceSession(sourceSessionId)) return;

    if (state.useExoPlayer && _videoViewController != null) {
      final controller = _videoViewController!;
      try {
        var durationMs = controller.mediaInfo.value?.duration ?? 0;
        if (durationMs <= 0) {
          final completer = Completer<void>();
          void listener() {
            if ((controller.mediaInfo.value?.duration ?? 0) > 0 &&
                !completer.isCompleted) {
              completer.complete();
            }
          }

          controller.mediaInfo.addListener(listener);
          try {
            await completer.future.timeout(
              const Duration(seconds: 8),
              onTimeout: () {},
            );
          } finally {
            controller.mediaInfo.removeListener(listener);
          }
          durationMs = controller.mediaInfo.value?.duration ?? 0;
        }
        if (!_isCurrentSourceSession(sourceSessionId)) return;
        final targetMs = durationMs > 0
            ? position.clamp(0, durationMs)
            : position;
        controller.seekTo(targetMs);
      } catch (_) {}
      return;
    }

    try {
      var duration = _player.state.duration;
      if (duration == Duration.zero) {
        duration = await _player.stream.duration
            .firstWhere((d) => d != Duration.zero)
            .timeout(const Duration(seconds: 8));
      }
      if (!_isCurrentSourceSession(sourceSessionId)) return;
      final maxMs = duration.inMilliseconds;
      if (maxMs <= 0) return;
      final targetMs = position.clamp(0, maxMs);
      await _player.seek(Duration(milliseconds: targetMs));
    } on TimeoutException {
      try {
        if (!_isCurrentSourceSession(sourceSessionId)) return;
        await _player.seek(Duration(milliseconds: position));
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _seekThenPlay(int positionMs) async {
    final sourceSessionId = state.sourceSessionId;
    if (positionMs <= 0 || !_isCurrentSourceSession(sourceSessionId)) return;
    await pause();
    if (!_isCurrentSourceSession(sourceSessionId)) return;
    await _safeSeekTo(positionMs);
    if (!_isCurrentSourceSession(sourceSessionId)) return;
    await _waitUntilNearResumePosition(positionMs);
    if (!_isCurrentSourceSession(sourceSessionId)) return;
    await play();
    if (!_isCurrentSourceSession(sourceSessionId)) return;
    await _waitUntilNearResumePosition(positionMs);
  }

  Future<void> _flushPendingResumeSeek() async {
    final sourceSessionId = state.sourceSessionId;
    if (!_isCurrentSourceSession(sourceSessionId)) return;
    final pos = _pendingResumeSeekPosition;
    if (pos == null ||
        !PlaybackResume.shouldHoldUntilSeeked(pos) ||
        _isApplyingPendingResumeSeek) {
      return;
    }

    _isApplyingPendingResumeSeek = true;
    try {
      await _seekThenPlay(pos);
    } catch (_) {
    } finally {
      if (_isCurrentSourceSession(sourceSessionId)) {
        _pendingResumeSeekPosition = null;
        _isApplyingPendingResumeSeek = false;
      }
    }
    if (!_isCurrentSourceSession(sourceSessionId)) return;
    _maybeConfirmPlaybackStarted(_currentPosition.inMilliseconds);
  }

  Future<void> _waitUntilNearResumePosition(int targetMs) async {
    final sourceSessionId = state.sourceSessionId;
    if (!_isCurrentSourceSession(sourceSessionId)) return;
    bool near() => PlaybackResume.isNear(
      currentMs: _currentPosition.inMilliseconds,
      targetMs: targetMs,
    );
    if (near()) return;

    final deadline = DateTime.now().add(PlaybackResume.seekSettleTimeout);
    while (_isCurrentSourceSession(sourceSessionId) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (near()) return;
    }
  }

  Future<int> _resolveResumePosition({required bool isLive}) async {
    if (isLive) return 0;

    final historyRepo = ref.read(historyRepositoryProvider);
    final account = ref.read(animeWitcherAccountServiceProvider);
    final mainUrl = _item.url;
    final progressUrl = _currentProgressUrl;
    final episode = _resolveCurrentEpisode();
    final isSeries =
        _item.contentType == MultimediaContentType.series ||
        _item.contentType == MultimediaContentType.anime;

    int localPosition() {
      if (isSeries) {
        return historyRepo.getEpisodePosition(
          progressUrl,
          mainUrl: mainUrl,
          season: episode?.season,
          episode: episode?.episode,
        );
      }
      return historyRepo.getPosition(mainUrl);
    }

    final local = localPosition();
    if (!_hasRefreshedCloudProgress &&
        PlaybackResume.shouldHoldUntilSeeked(local)) {
      _hasRefreshedCloudProgress = true;
      unawaited(_syncContinueWatchingInBackground());
    }
    return PlaybackResume.resolveStartupPosition(
      localPositionMs: local,
      cloudPositionMs: () async {
        _hasRefreshedCloudProgress = true;
        try {
          await account.syncContinueWatchingItem(mainUrl);
        } catch (_) {}
        final afterSync = localPosition();
        if (PlaybackResume.shouldHoldUntilSeeked(afterSync)) {
          return afterSync;
        }
        if (isSeries && episode != null) {
          return account.remoteEpisodePosition(
            mainUrl: mainUrl,
            episodeUrl: progressUrl,
            refresh: true,
          );
        }
        return afterSync;
      },
    );
  }

  Future<void> _syncContinueWatchingInBackground() async {
    try {
      await ref
          .read(animeWitcherAccountServiceProvider)
          .syncContinueWatchingItem(_item.url);
    } catch (_) {}
  }

  Future<void> setPlaybackSpeed(double rate, {bool persist = false}) async {
    final appliedRate = rate.clamp(0.5, state.maxPlaybackSpeed);

    if (state.useExoPlayer && _videoViewController != null) {
      _videoViewController!.setSpeed(appliedRate);
      state = state.copyWith(playbackSpeed: appliedRate);
    } else {
      await _player.setRate(appliedRate);
      state = state.copyWith(playbackSpeed: appliedRate);
    }

    if (persist) {
      unawaited(
        ref
            .read(playerSettingsProvider.notifier)
            .setDefaultPlaybackSpeed(appliedRate),
      );
    }
  }

  Future<void> setSubtitleDelay(double seconds) async {
    if (!state.supportsSubtitleDelay) return;

    final native = _player.platform;
    if (native is NativePlayer) {
      await native.setProperty('sub-delay', seconds.toString());
      state = state.copyWith(subtitleDelay: seconds);
    }
  }

  Future<void> applySubtitleSettings() async {
    if (_isDisposed || !state.supportsSubtitleStyling) return;

    final native = _player.platform;
    if (native is NativePlayer) {
      final settings =
          ref.read(playerSettingsProvider).asData?.value ??
          const PlayerSettings();

      await native.setProperty(
        'sub-font-size',
        settings.subtitleSize.toString(),
      );
      await native.setProperty(
        'sub-pos',
        settings.subtitlePosition.round().toString(),
      );

      String colorToMpvHex(int color, [double opacity = 1.0]) {
        final alpha = (opacity * 255).toInt().toRadixString(16).padLeft(2, '0');
        final rgb = color.toRadixString(16).padLeft(8, '0').substring(2);
        return '#$alpha$rgb';
      }

      await native.setProperty(
        'sub-color',
        colorToMpvHex(settings.subtitleColor),
      );
      if (settings.subtitleBackgroundColor != 0x00000000) {
        await native.setProperty(
          'sub-back-color',
          colorToMpvHex(
            settings.subtitleBackgroundColor,
            settings.subtitleBackgroundOpacity,
          ),
        );
      } else {
        await native.setProperty('sub-back-color', '#00000000');
      }

      await native.setProperty('sub-visibility', 'no');
    }
  }

  double _getEngineVolumeLevel() {
    if (state.useExoPlayer && _videoViewController != null) {
      return _videoViewController!.volume.value.clamp(0.0, 1.0);
    }
    return (_player.state.volume / 100).clamp(0.0, 2.0);
  }

  Future<void> _setEngineVolumeLevel(double value) async {
    if (state.useExoPlayer && _videoViewController != null) {
      _videoViewController!.setVolume(value.clamp(0.0, 1.0));
      return;
    }
    await _player.setVolume((value * 100).clamp(0.0, 200.0));
  }

  Future<double> getVolumeLevel() async {
    final value = _getEngineVolumeLevel();
    if (value > 0) _lastNonZeroVolumeLevel = value;
    return value;
  }

  Future<double> setVolumeLevel(double value) async {
    final target = value.clamp(0.0, state.supportsVolumeBoost ? 2.0 : 1.0);
    if (target > 0) _lastNonZeroVolumeLevel = target;
    await _setEngineVolumeLevel(target);
    return target;
  }

  Future<double> changeVolume(double step) async {
    final current = await getVolumeLevel();
    final boostStep = state.supportsVolumeBoost && current >= 1.0
        ? step * 2
        : step;
    return setVolumeLevel(current + boostStep);
  }

  Future<double> toggleMute() async {
    final current = await getVolumeLevel();
    if (current > 0) return setVolumeLevel(0.0);
    return setVolumeLevel(_lastNonZeroVolumeLevel);
  }

  Future<void> loadExternalSubtitleFile({String? filePath}) async {
    if (state.useExoPlayer && !state.supportsExternalSubtitleLoading) return;

    String? path = filePath;
    if (path == null) {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'vtt', 'ass', 'ssa'],
      );
      if (result != null && result.files.single.path != null) {
        path = result.files.single.path!;
      }
    }

    if (path != null) {
      final ext = p.extension(path).toLowerCase().replaceAll('.', '');
      final baseName = p.basenameWithoutExtension(path).trim();
      final label = baseName.isNotEmpty ? baseName : 'External ($ext)';
      final newSub = SubtitleFile(url: path, label: label, lang: 'und');

      state = state.copyWith(
        externalSubtitles: _effectiveExternalSubtitles(
          state.currentStream?.subtitles,
        ),
      );

      if (!_userAddedExternalSubtitles.any((sub) => sub.url == newSub.url)) {
        _userAddedExternalSubtitles.add(newSub);
        state = state.copyWith(
          externalSubtitles: _effectiveExternalSubtitles(
            state.currentStream?.subtitles,
          ),
        );
      }

      if (state.useExoPlayer && state.currentStream != null) {
        pendingVideoViewSubtitleIdsBeforeReload = _videoViewController
            ?.mediaInfo
            .value
            ?.subtitleTracks
            .keys
            .toSet();
        selectNewestVideoViewSubtitleAfterReload =
            !(Platform.isMacOS || Platform.isIOS);

        await changeStream(state.currentStream!, resetPosition: false);

        if (!state.useExoPlayer) {
          pendingVideoViewSubtitleIdsBeforeReload = null;
          selectNewestVideoViewSubtitleAfterReload = false;
          await selectSubtitleTrack('external:${newSub.url}');
        }
        return;
      }

      await selectSubtitleTrack('external:${newSub.url}');
    }
  }
}

final playerControllerProvider =
    NotifierProvider.autoDispose<PlayerController, PlayerState>(
      PlayerController.new,
    );

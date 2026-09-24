import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/entity/manga.dart';
import '../../utils/manga_image_request_headers.dart';
import '../download_parallel.dart';
import 'background_downloader_gateway.dart';
import 'download_v2_models.dart';
import 'manga_chapter_manifest_v2.dart';

final class MangaChapterTransportSpecV2 {
  const MangaChapterTransportSpecV2({
    required this.taskId,
    required this.mangaId,
    required this.chapterId,
    required this.destinationDirectory,
    required this.pages,
    required this.retries,
    this.maxConcurrentPages = 4,
  }) : assert(taskId != ''),
       assert(mangaId != ''),
       assert(chapterId != ''),
       assert(destinationDirectory != ''),
       assert(retries >= 0),
       assert(maxConcurrentPages > 0);

  final String taskId;
  final String mangaId;
  final String chapterId;
  final String destinationDirectory;
  final List<MangaPage> pages;
  final int retries;
  final int maxConcurrentPages;
}

final class MangaChapterPageTaskV2 {
  const MangaChapterPageTaskV2({
    required this.taskId,
    required this.pageIndex,
    required this.url,
    required this.headers,
    required this.destinationPath,
    required this.retries,
  });

  final String taskId;
  final int pageIndex;
  final String url;
  final Map<String, String> headers;
  final String destinationPath;
  final int retries;
}

abstract interface class MangaChapterPageResolverV2 {
  Future<List<MangaPage>> resolve(Map<String, Object?> descriptor);
}

abstract interface class MangaChapterGatewayV2 {
  Future<DownloadTransportHandle> startMangaChapter(
    MangaChapterTransportSpecV2 spec,
  );
}

typedef MangaChapterPageStarterV2 =
    Future<DownloadTransportHandle> Function(MangaChapterPageTaskV2 task);

typedef MangaChapterDirectoryResolverV2 =
    Future<Directory> Function(String path);

Future<Directory> resolveMangaChapterDirectoryV2(String rawPath) async {
  if (p.isAbsolute(rawPath)) return Directory(rawPath);
  final documents = await getApplicationDocumentsDirectory();
  return Directory(p.join(documents.path, rawPath));
}

final class MangaChapterTransportV2 {
  MangaChapterTransportV2({
    required this.startPage,
    MangaChapterDirectoryResolverV2? resolveDirectory,
  }) : resolveDirectory =
           resolveDirectory ?? resolveMangaChapterDirectoryV2;

  final MangaChapterPageStarterV2 startPage;
  final MangaChapterDirectoryResolverV2 resolveDirectory;

  Future<DownloadTransportHandle> start(
    MangaChapterTransportSpecV2 spec,
  ) async {
    final directory = await resolveDirectory(spec.destinationDirectory);
    await directory.create(recursive: true);

    var manifest = await MangaChapterManifestV2.readFrom(directory);
    if (manifest == null ||
        manifest.mangaId != spec.mangaId ||
        manifest.chapterId != spec.chapterId ||
        manifest.pageCount != spec.pages.length) {
      manifest = MangaChapterManifestV2(
        version: MangaChapterManifestV2.currentVersion,
        mangaId: spec.mangaId,
        chapterId: spec.chapterId,
        pageCount: spec.pages.length,
        completedIndexes: const <int>{},
        isComplete: spec.pages.isEmpty,
      );
      await manifest.writeTo(directory);
    }

    final verified = <int>{};
    for (final index in manifest.completedIndexes) {
      if (index < 0 || index >= spec.pages.length) continue;
      final file = File(
        p.join(directory.path, _pageFileName(index, spec.pages[index])),
      );
      if (await file.exists() && await file.length() > 0) verified.add(index);
    }
    manifest = manifest.copyWith(
      completedIndexes: verified,
      isComplete: verified.length == spec.pages.length,
    );
    await manifest.writeTo(directory);

    final handle = _MangaChapterTransportHandle(
      spec: spec,
      directory: directory,
      manifest: manifest,
      startPage: startPage,
    );
    unawaited(handle.start());
    return handle;
  }
}

String _pageFileName(int index, MangaPage page) {
  final uri = Uri.tryParse(page.imageUrl);
  final ext = uri == null ? '' : p.extension(uri.path).toLowerCase();
  const allowed = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.avif',
  };
  final safeExt = allowed.contains(ext) ? ext : '.img';
  return '${(index + 1).toString().padLeft(4, '0')}$safeExt';
}

final class _MangaChapterTransportHandle implements DownloadTransportHandle {
  _MangaChapterTransportHandle({
    required this.spec,
    required this.directory,
    required MangaChapterManifestV2 manifest,
    required this.startPage,
  }) : _manifest = manifest,
       _current = DownloadTransportSnapshot(
         taskId: spec.taskId,
         status: manifest.isComplete
             ? DownloadTransportStatus.complete
             : DownloadTransportStatus.queued,
         progress: manifest.isComplete ? 1 : _baseProgress(manifest),
         configuredConnections: _boundedPageConnections(spec.maxConcurrentPages),
         activeConnections: 0,
       );

  final MangaChapterTransportSpecV2 spec;
  final Directory directory;
  final MangaChapterPageStarterV2 startPage;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast();
  final Map<int, DownloadTransportHandle> _pageHandles =
      <int, DownloadTransportHandle>{};
  final Map<int, StreamSubscription<DownloadTransportSnapshot>>
  _pageSubscriptions = <int, StreamSubscription<DownloadTransportSnapshot>>{};
  final Set<int> _startingIndexes = <int>{};
  final Map<int, Future<void>> _startingPages = <int, Future<void>>{};

  MangaChapterManifestV2 _manifest;
  DownloadTransportSnapshot _current;
  Future<void> _pageCompletionTail = Future<void>.value();
  bool _paused = false;
  bool _canceled = false;
  bool _canceling = false;
  bool _scheduling = false;
  int _generation = 0;

  int get _pageConnectionLimit =>
      _boundedPageConnections(spec.maxConcurrentPages);

  @override
  String get taskId => spec.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  Future<void> start() async {
    if (_manifest.isComplete) {
      _emit(_current);
      return;
    }
    _scheduleAvailablePages();
  }

  void _scheduleAvailablePages() {
    if (_scheduling ||
        _paused ||
        _canceled ||
        _canceling ||
        _current.isFinal) {
      return;
    }
    _scheduling = true;
    _fillAvailableSlots();
  }

  void _fillAvailableSlots() {
    try {
      while (!_paused &&
          !_canceled &&
          !_canceling &&
          !_current.isFinal &&
          _pageHandles.length + _startingIndexes.length <
              _pageConnectionLimit) {
        final index = _firstMissingIndex();
        if (index == null) break;

        _startingIndexes.add(index);
        final start = _startPage(index, _generation);
        _startingPages[index] = start;
        unawaited(start);
      }
    } catch (error) {
      if (!_current.isFinal) {
        unawaited(
          _fail(
            category: DownloadFailureCategory.filesystem,
            message: error.toString(),
          ),
        );
      }
    } finally {
      _scheduling = false;
    }
  }

  int? _firstMissingIndex() {
    for (var index = 0; index < spec.pages.length; index++) {
      if (_manifest.completedIndexes.contains(index) ||
          _pageHandles.containsKey(index) ||
          _startingIndexes.contains(index)) {
        continue;
      }
      return index;
    }
    return null;
  }

  Future<void> _startPage(int index, int generation) async {
    try {
      final page = spec.pages[index];
      final pageTask = MangaChapterPageTaskV2(
        taskId: '${taskId}_p${(index + 1).toString().padLeft(4, '0')}',
        pageIndex: index,
        url: page.imageUrl,
        headers: mangaImageRequestHeaders(page.headers),
        destinationPath: p.join(
          directory.path,
          _pageFileName(index, page),
        ),
        retries: spec.retries,
      );
      final handle = await startPage(pageTask);
      _startingIndexes.remove(index);
      _startingPages.remove(index);
      if (_canceled || generation != _generation || _current.isFinal) {
        await handle.cancel();
        return;
      }

      _pageHandles[index] = handle;
      _pageSubscriptions[index] = handle.snapshots.listen(
        (snapshot) => _dispatchPageSnapshot(index, generation, snapshot),
      );
      _emitAggregate(
        _paused &&
                handle.current.status == DownloadTransportStatus.paused
            ? DownloadTransportStatus.paused
            : DownloadTransportStatus.running,
      );
      final currentPage = handle.current;
      if (currentPage.isFinal ||
          currentPage.status == DownloadTransportStatus.missing) {
        unawaited(
          Future<void>.delayed(
            Duration.zero,
            () => _dispatchPageSnapshot(index, generation, currentPage),
          ),
        );
      }
    } catch (error) {
      _startingIndexes.remove(index);
      _startingPages.remove(index);
      if (!_canceled && generation == _generation && !_current.isFinal) {
        await _fail(
          category: DownloadFailureCategory.transport,
          message: error.toString(),
        );
      }
    }
  }

  void _dispatchPageSnapshot(
    int index,
    int generation,
    DownloadTransportSnapshot snapshot,
  ) {
    if (snapshot.status != DownloadTransportStatus.complete) {
      unawaited(_onPageSnapshot(index, generation, snapshot));
      return;
    }

    final previous = _pageCompletionTail;
    final next = previous
        .catchError((Object _, StackTrace __) {})
        .then<void>((_) => _onPageSnapshot(index, generation, snapshot));
    _pageCompletionTail = next.catchError((Object error, StackTrace _) {
      if (_canceled || generation != _generation || _current.isFinal) return;
      unawaited(
        _fail(
          category: DownloadFailureCategory.filesystem,
          message: error.toString(),
        ),
      );
    });
  }

  Future<void> _onPageSnapshot(
    int index,
    int generation,
    DownloadTransportSnapshot snapshot,
  ) async {
    if (_canceled ||
        _canceling ||
        generation != _generation ||
        _current.isFinal) {
      return;
    }

    if (snapshot.status == DownloadTransportStatus.complete) {
      // Package streams can repeat a terminal callback. Once durably
      // checkpointed, a duplicate must not rewrite the manifest.
      if (_manifest.completedIndexes.contains(index)) return;

      final file = File(
        p.join(directory.path, _pageFileName(index, spec.pages[index])),
      );
      if (!await file.exists() || await file.length() <= 0) {
        await _fail(
          category: DownloadFailureCategory.integrity,
          message: 'Manga page file is missing or empty',
        );
        return;
      }
      if (_canceled || generation != _generation || _current.isFinal) return;

      final completed = Set<int>.from(_manifest.completedIndexes)..add(index);
      _manifest = _manifest.copyWith(
        completedIndexes: completed,
        isComplete: completed.length == spec.pages.length,
      );
      await _manifest.writeTo(directory);
      if (_canceled || generation != _generation || _current.isFinal) return;
      await _pageSubscriptions.remove(index)?.cancel();
      _pageHandles.remove(index);

      if (_manifest.isComplete) {
        _emitAggregate(DownloadTransportStatus.complete, progress: 1);
      } else {
        _emitAggregate(
          _paused
              ? DownloadTransportStatus.paused
              : DownloadTransportStatus.running,
        );
        _scheduleAvailablePages();
      }
      return;
    }

    if (snapshot.status == DownloadTransportStatus.missing) {
      await _fail(
        category: DownloadFailureCategory.sourceExpired,
        message: 'Manga page source returned HTTP 404',
      );
      return;
    }

    if (snapshot.status == DownloadTransportStatus.failed) {
      await _fail(
        category: snapshot.failureCategory ?? DownloadFailureCategory.transport,
        message: snapshot.failureMessage,
      );
      return;
    }

    if (snapshot.status == DownloadTransportStatus.canceled) {
      await _pageSubscriptions.remove(index)?.cancel();
      _pageHandles.remove(index);
      _emitAggregate(
        _paused && _allPagesPaused()
            ? DownloadTransportStatus.paused
            : DownloadTransportStatus.running,
      );
      _scheduleAvailablePages();
      return;
    }

    _emitAggregate(
      _paused && _allPagesPaused()
          ? DownloadTransportStatus.paused
          : DownloadTransportStatus.running,
    );
  }

  Future<void> _fail({
    required DownloadFailureCategory category,
    required String? message,
  }) async {
    if (_current.isFinal) return;
    final aggregate = _aggregate(DownloadTransportStatus.failed);
    _emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.failed,
        progress: aggregate.progress,
        configuredConnections: _pageConnectionLimit,
        activeConnections: aggregate.activeConnections,
        failureCategory: category,
        failureMessage: message,
      ),
    );
    await _cancelActivePages();
  }

  DownloadTransportSnapshot _aggregate(
    DownloadTransportStatus status, {
    double? progress,
  }) {
    final pageCount = spec.pages.length;
    var completedProgress = _manifest.completedIndexes.length.toDouble();
    var activeConnections = _startingIndexes.length;
    var networkSpeed = 0.0;
    var hasNetworkSpeed = false;
    Duration? timeRemaining;

    for (final handle in _pageHandles.values) {
      final page = handle.current;
      completedProgress += page.progress.clamp(0.0, 1.0).toDouble();
      if (page.status == DownloadTransportStatus.running) activeConnections++;
      if (page.networkSpeedMBps >= 0) {
        networkSpeed += page.networkSpeedMBps;
        hasNetworkSpeed = true;
      }
      if (page.timeRemaining > (timeRemaining ?? Duration.zero)) {
        timeRemaining = page.timeRemaining;
      }
    }

    final aggregateProgress = progress ??
        (pageCount == 0
            ? 1.0
            : (completedProgress / pageCount).clamp(0.0, 1.0).toDouble());
    return DownloadTransportSnapshot(
      taskId: taskId,
      status: status,
      progress: aggregateProgress,
      networkSpeedMBps: hasNetworkSpeed ? networkSpeed : -1,
      timeRemaining: timeRemaining ?? Duration.zero,
      configuredConnections: _pageConnectionLimit,
      activeConnections: activeConnections,
    );
  }

  void _emitAggregate(
    DownloadTransportStatus status, {
    double? progress,
  }) {
    _emit(_aggregate(status, progress: progress));
  }

  static int _boundedPageConnections(int value) =>
      value.clamp(kDownloadPartsMin, kDownloadPartsMax).toInt();

  static double _baseProgress(MangaChapterManifestV2 manifest) {
    if (manifest.pageCount <= 0) return manifest.isComplete ? 1 : 0;
    return (manifest.completedIndexes.length / manifest.pageCount)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  bool _allPagesPaused() =>
      _startingIndexes.isEmpty &&
      _pageHandles.values.every(
        (handle) =>
            handle.current.isFinal ||
            handle.current.status == DownloadTransportStatus.paused,
      );

  Future<void> _cancelActivePages() async {
    final subscriptions =
        List<StreamSubscription<DownloadTransportSnapshot>>.from(
          _pageSubscriptions.values,
        );
    _pageSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }

    final handles = List<DownloadTransportHandle>.from(_pageHandles.values);
    _pageHandles.clear();
    await Future.wait(handles.map((handle) async => handle.cancel()));
  }

  Future<void> _releasePageHandles() async {
    final subscriptions =
        List<StreamSubscription<DownloadTransportSnapshot>>.from(
          _pageSubscriptions.values,
        );
    _pageSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    _pageHandles.clear();
  }

  void _emit(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    if (!_controller.isClosed) _controller.add(snapshot);
  }

  @override
  Future<bool> pause() async {
    if (_current.isFinal) return false;
    _paused = true;
    await Future.wait(_startingPages.values.toList(growable: false));
    if (_current.isFinal) return false;

    final handles = _pageHandles.values
        .where((handle) => !handle.current.isFinal)
        .toList(growable: false);
    final handlesToPause = handles
        .where((handle) =>
            handle.current.status != DownloadTransportStatus.paused)
        .toList(growable: false);
    final results = await Future.wait<bool>(
      handlesToPause.map((handle) => handle.pause()),
    );
    if (_current.isFinal) return false;
    if (results.any((accepted) => !accepted)) {
      final handlesToResume = <DownloadTransportHandle>[
        for (var index = 0; index < results.length; index++)
          if (results[index]) handlesToPause[index],
      ];
      final resumeResults = await Future.wait<bool>(
        handlesToResume.map((handle) => handle.resume()),
      );
      final rolledBack = resumeResults.every((accepted) => accepted);
      _paused = !rolledBack;
      if (rolledBack) {
        _emitAggregate(DownloadTransportStatus.running);
        _scheduleAvailablePages();
      } else {
        _emitAggregate(
          _allPagesPaused()
              ? DownloadTransportStatus.paused
              : DownloadTransportStatus.running,
        );
      }
      return false;
    }
    if (_allPagesPaused()) _emitAggregate(DownloadTransportStatus.paused);
    return true;
  }

  @override
  Future<bool> resume() async {
    if (_canceled || _current.isFinal) return false;
    _paused = false;
    final handles = _pageHandles.values
        .where((handle) =>
            handle.current.status == DownloadTransportStatus.paused)
        .toList(growable: false);
    final results = await Future.wait(
      handles.map((handle) async => handle.resume()),
    );
    if (results.any((accepted) => !accepted)) {
      _paused = true;
      return false;
    }

    if (handles.isEmpty) _emitAggregate(DownloadTransportStatus.running);
    _scheduleAvailablePages();
    return true;
  }

  @override
  Future<bool> cancel() async {
    if (_canceled) return true;
    if (_current.isFinal) return false;
    if (_canceling) return false;
    _canceling = true;
    await Future.wait(_startingPages.values.toList(growable: false));
    if (_current.isFinal) {
      _canceling = false;
      return false;
    }

    final entries = _pageHandles.entries.toList(growable: false);
    final results = await Future.wait<bool>(
      entries.map((entry) async {
        if (entry.value.current.isFinal) return true;
        try {
          return await entry.value.cancel();
        } catch (_) {
          return false;
        }
      }),
    );
    if (results.any((accepted) => !accepted)) {
      _canceling = false;
      for (final entry in _pageHandles.entries.toList(growable: false)) {
        final current = entry.value.current;
        if (current.isFinal ||
            current.status == DownloadTransportStatus.missing) {
          _dispatchPageSnapshot(entry.key, _generation, current);
        }
      }
      if (!_current.isFinal && !_paused) {
        _emitAggregate(DownloadTransportStatus.running);
        _scheduleAvailablePages();
      }
      return false;
    }

    final progress = _aggregate(DownloadTransportStatus.canceled).progress;
    _canceled = true;
    _generation++;
    _canceling = false;
    await _releasePageHandles();
    _emitAggregate(DownloadTransportStatus.canceled, progress: progress);
    return true;
  }
}

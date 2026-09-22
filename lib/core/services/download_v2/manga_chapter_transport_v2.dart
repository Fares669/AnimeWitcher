import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/entity/manga.dart';
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
  }) : assert(taskId != ''),
       assert(mangaId != ''),
       assert(chapterId != ''),
       assert(destinationDirectory != ''),
       assert(retries >= 0);

  final String taskId;
  final String mangaId;
  final String chapterId;
  final String destinationDirectory;
  final List<MangaPage> pages;
  final int retries;
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
      isComplete: spec.pages.isNotEmpty && verified.length == spec.pages.length,
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
       );

  final MangaChapterTransportSpecV2 spec;
  final Directory directory;
  final MangaChapterPageStarterV2 startPage;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast();

  MangaChapterManifestV2 _manifest;
  DownloadTransportSnapshot _current;
  DownloadTransportHandle? _pageHandle;
  StreamSubscription<DownloadTransportSnapshot>? _pageSubscription;
  Future<void> _pageCompletionTail = Future<void>.value();
  bool _paused = false;
  bool _canceled = false;
  bool _starting = false;
  int _generation = 0;

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
    await _startNext();
  }

  Future<void> _startNext() async {
    if (_starting || _paused || _canceled || _manifest.isComplete) return;
    final index = _firstMissingIndex();
    if (index == null) {
      _manifest = _manifest.copyWith(isComplete: true);
      await _manifest.writeTo(directory);
      _emit(
        DownloadTransportSnapshot(
          taskId: taskId,
          status: DownloadTransportStatus.complete,
          progress: 1,
        ),
      );
      return;
    }

    _starting = true;
    final generation = ++_generation;
    try {
      final page = spec.pages[index];
      final pageTask = MangaChapterPageTaskV2(
        taskId: '${taskId}_p${(index + 1).toString().padLeft(4, '0')}',
        pageIndex: index,
        url: page.imageUrl,
        headers: page.headers,
        destinationPath: p.join(
          directory.path,
          _pageFileName(index, page),
        ),
        retries: spec.retries,
      );
      final handle = await startPage(pageTask);
      if (_canceled || generation != _generation) {
        await handle.cancel();
        return;
      }
      _pageHandle = handle;
      await _pageSubscription?.cancel();
      _pageSubscription = handle.snapshots.listen(
        (snapshot) => _dispatchPageSnapshot(index, generation, snapshot),
      );
      final currentPage = handle.current;
      _emit(_aggregate(currentPage));
      if (currentPage.isFinal) {
        unawaited(
          Future<void>.delayed(
            Duration.zero,
            () => _dispatchPageSnapshot(index, generation, currentPage),
          ),
        );
      }
    } catch (error) {
      _emit(
        DownloadTransportSnapshot(
          taskId: taskId,
          status: DownloadTransportStatus.failed,
          progress: current.progress,
          failureCategory: DownloadFailureCategory.transport,
          failureMessage: error.toString(),
        ),
      );
    } finally {
      _starting = false;
    }
  }

  int? _firstMissingIndex() {
    for (var index = 0; index < spec.pages.length; index++) {
      if (!_manifest.completedIndexes.contains(index)) return index;
    }
    return null;
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
      if (_canceled || generation != _generation) return;
      _emit(
        DownloadTransportSnapshot(
          taskId: taskId,
          status: DownloadTransportStatus.failed,
          progress: current.progress,
          failureCategory: DownloadFailureCategory.filesystem,
          failureMessage: error.toString(),
        ),
      );
    });
  }

  Future<void> _onPageSnapshot(
    int index,
    int generation,
    DownloadTransportSnapshot snapshot,
  ) async {
    if (_canceled || generation != _generation) return;

    if (snapshot.status == DownloadTransportStatus.complete &&
        _manifest.completedIndexes.contains(index)) {
      return;
    }

    if (snapshot.status == DownloadTransportStatus.complete) {
      // Package streams can repeat the same terminal callback. Once this page
      // is durably checkpointed, a duplicate must not rewrite manifest.json
      // and briefly remove the authoritative checkpoint.
      if (_manifest.completedIndexes.contains(index)) return;

      final file = File(
        p.join(directory.path, _pageFileName(index, spec.pages[index])),
      );
      if (!await file.exists() || await file.length() <= 0) {
        _emit(
          DownloadTransportSnapshot(
            taskId: taskId,
            status: DownloadTransportStatus.failed,
            progress: current.progress,
            failureCategory: DownloadFailureCategory.integrity,
            failureMessage: 'Manga page file is missing or empty',
          ),
        );
        return;
      }

      final completed = Set<int>.from(_manifest.completedIndexes)..add(index);
      _manifest = _manifest.copyWith(
        completedIndexes: completed,
        isComplete: completed.length == spec.pages.length,
      );
      await _manifest.writeTo(directory);
      await _pageSubscription?.cancel();
      _pageSubscription = null;
      _pageHandle = null;

      if (_manifest.isComplete) {
        _emit(
          DownloadTransportSnapshot(
            taskId: taskId,
            status: DownloadTransportStatus.complete,
            progress: 1,
          ),
        );
      } else if (!_paused) {
        _emit(
          DownloadTransportSnapshot(
            taskId: taskId,
            status: DownloadTransportStatus.queued,
            progress: _baseProgress(_manifest),
          ),
        );
        await _startNext();
      }
      return;
    }

    if (snapshot.status == DownloadTransportStatus.failed ||
        snapshot.status == DownloadTransportStatus.canceled) {
      _emit(
        DownloadTransportSnapshot(
          taskId: taskId,
          status: snapshot.status,
          progress: _aggregate(snapshot).progress,
          failureCategory: snapshot.failureCategory,
          failureMessage: snapshot.failureMessage,
        ),
      );
      return;
    }

    if (snapshot.status == DownloadTransportStatus.paused) {
      _emit(
        DownloadTransportSnapshot(
          taskId: taskId,
          status: DownloadTransportStatus.paused,
          progress: _aggregate(snapshot).progress,
        ),
      );
      return;
    }

    _emit(_aggregate(snapshot));
  }

  DownloadTransportSnapshot _aggregate(DownloadTransportSnapshot page) {
    final pageCount = spec.pages.length;
    final completed = _manifest.completedIndexes.length;
    final progress = pageCount == 0
        ? 1.0
        : ((completed + page.progress.clamp(0.0, 1.0)) / pageCount)
              .clamp(0.0, 1.0)
              .toDouble();
    final parentStatus =
        page.status == DownloadTransportStatus.complete && !_manifest.isComplete
        ? DownloadTransportStatus.running
        : page.status;
    return DownloadTransportSnapshot(
      taskId: taskId,
      status: parentStatus,
      progress: progress,
      networkSpeedMBps: page.networkSpeedMBps,
      timeRemaining: page.timeRemaining,
      configuredConnections: 1,
      activeConnections: page.status == DownloadTransportStatus.running ? 1 : 0,
      failureCategory: page.failureCategory,
      failureMessage: page.failureMessage,
    );
  }

  static double _baseProgress(MangaChapterManifestV2 manifest) {
    if (manifest.pageCount <= 0) return manifest.isComplete ? 1 : 0;
    return (manifest.completedIndexes.length / manifest.pageCount)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  void _emit(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    if (!_controller.isClosed) _controller.add(snapshot);
  }

  @override
  Future<bool> pause() async {
    if (_current.isFinal) return false;
    _paused = true;
    final handle = _pageHandle;
    if (handle == null) {
      _emit(
        DownloadTransportSnapshot(
          taskId: taskId,
          status: DownloadTransportStatus.paused,
          progress: current.progress,
        ),
      );
      return true;
    }
    final accepted = await handle.pause();
    if (!accepted) _paused = false;
    return accepted;
  }

  @override
  Future<bool> resume() async {
    if (_canceled || _manifest.isComplete) return false;
    _paused = false;
    final handle = _pageHandle;
    if (handle != null &&
        handle.current.status == DownloadTransportStatus.paused) {
      return handle.resume();
    }
    await _startNext();
    return true;
  }

  @override
  Future<bool> cancel() async {
    if (_canceled) return true;
    _canceled = true;
    _generation++;
    await _pageSubscription?.cancel();
    _pageSubscription = null;
    final accepted = await _pageHandle?.cancel() ?? true;
    _pageHandle = null;
    _emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.canceled,
        progress: current.progress,
      ),
    );
    return accepted;
  }
}

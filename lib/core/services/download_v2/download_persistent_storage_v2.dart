import 'package:background_downloader/background_downloader.dart';

import '../../storage/download_persistence_worker.dart';

FileDownloader? _configuredFileDownloader;
final _configuredPersistentStorage = DownloadPersistentStorageV2();

/// Installs the worker-backed store on the first use of the package singleton.
FileDownloader configuredFileDownloaderV2() => _configuredFileDownloader ??=
    FileDownloader(persistentStorage: _configuredPersistentStorage);

/// Retires only the obsolete source checkpoint in the store supplied to the
/// production package instance. It never interprets opaque native resume data.
Future<void> retireConfiguredResumeCheckpointV2(String taskId) async {
  await _configuredPersistentStorage.removeResumeData(taskId);
  await _configuredPersistentStorage.removePausedTask(taskId);
}

/// Fence late native checkpoint callbacks after confirmed cancellation.
Future<void> discardConfiguredResumeCheckpointV2(String taskId) =>
    _configuredPersistentStorage.discardTask(taskId);

/// Keeps the package's Localstore v1 layout while sharing the download worker.
///
/// Data reads and writes await initialization. File operations and JSON encoding
/// run on the worker, and failures reach callers instead of being swallowed.
final class DownloadPersistentStorageV2 implements PersistentStorage {
  DownloadPersistentStorageV2({DownloadPersistenceWorker? worker})
    : _worker = worker == null ? null : Future.value(worker);

  static const taskRecordsPath = LocalStorePersistentStorage.taskRecordsPath;
  static const resumeDataPath = LocalStorePersistentStorage.resumeDataPath;
  static const pausedTasksPath = LocalStorePersistentStorage.pausedTasksPath;
  static final _illegalPathCharacters = RegExp(r'[\\/:*?"<>|]');

  final _discardedTasks = <String>{};

  Future<void> discardTask(String taskId) async {
    _discardedTasks.add(taskId);
    await removeResumeData(taskId);
    await removePausedTask(taskId);
    await removeTaskRecord(taskId);
  }

  Future<DownloadPersistenceWorker>? _worker;
  Future<void>? _initialization;

  Future<DownloadPersistenceWorker> _getWorker() =>
      _worker ??= DownloadPersistenceWorker.application();

  @override
  (String, int) get currentDatabaseVersion => ('Localstore', 1);

  @override
  Future<(String, int)> get storedDatabaseVersion async => (
    'Localstore',
    await (await _getWorker()).run('local.version', []) as int,
  );

  @override
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      final worker = await _getWorker();
      await worker.run('local.initialize', [
        [resumeDataPath, pausedTasksPath, taskRecordsPath],
      ]);
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<dynamic> _run(String operation, List<Object?> arguments) async {
    await initialize();
    return (await _getWorker()).run(operation, arguments);
  }

  String _safeId(String id) => id.replaceAll(_illegalPathCharacters, '_');

  Future<void> _store(
    String collection,
    String taskId,
    Map<String, dynamic> json,
  ) async {
    if (_discardedTasks.contains(taskId)) return;
    await _run('local.put', [collection, _safeId(taskId), json]);
  }

  Future<T?> _retrieve<T>(
    String collection,
    String taskId,
    T Function(Map<String, dynamic>) fromJson,
  ) async {
    final json = await _run('local.get', [collection, _safeId(taskId)]);
    return json == null
        ? null
        : fromJson(Map<String, dynamic>.from(json as Map));
  }

  Future<List<T>> _retrieveAll<T>(
    String collection,
    T Function(Map<String, dynamic>) fromJson,
  ) async {
    final rows = await _run('local.all', [collection]) as List;
    return rows
        .map((row) => fromJson(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  Future<void> _remove(String collection, String? taskId) async {
    await _run('local.remove', [
      collection,
      taskId == null ? null : _safeId(taskId),
    ]);
  }

  @override
  Future<void> storeTaskRecord(TaskRecord record) =>
      _store(taskRecordsPath, record.taskId, record.toJson());

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) =>
      _retrieve(taskRecordsPath, taskId, TaskRecord.fromJson);

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() =>
      _retrieveAll(taskRecordsPath, TaskRecord.fromJson);

  @override
  Future<void> removeTaskRecord(String? taskId) =>
      _remove(taskRecordsPath, taskId);

  @override
  Future<void> storePausedTask(Task task) =>
      _store(pausedTasksPath, task.taskId, task.toJson());

  @override
  Future<Task?> retrievePausedTask(String taskId) =>
      _retrieve(pausedTasksPath, taskId, Task.createFromJson);

  @override
  Future<List<Task>> retrieveAllPausedTasks() =>
      _retrieveAll(pausedTasksPath, Task.createFromJson);

  @override
  Future<void> removePausedTask(String? taskId) =>
      _remove(pausedTasksPath, taskId);

  @override
  Future<void> storeResumeData(ResumeData resumeData) =>
      _store(resumeDataPath, resumeData.taskId, resumeData.toJson());

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) =>
      _retrieve(resumeDataPath, taskId, ResumeData.fromJson);

  @override
  Future<List<ResumeData>> retrieveAllResumeData() =>
      _retrieveAll(resumeDataPath, ResumeData.fromJson);

  @override
  Future<void> removeResumeData(String? taskId) =>
      _remove(resumeDataPath, taskId);
}

/// Deterministic metadata and cache keys for Anime4K shader files.
///
/// The player and settings preview ask for the same shader folder frequently.
/// Reading and hashing every GLSL file on every apply would turn a cheap
/// configuration lookup into repeated disk I/O. This manifest keeps the
/// cryptographic identity needed by the Metal pipeline cache while reusing it
/// until filesystem metadata says the folder or one of its known files changed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class Anime4kShaderEntry {
  const Anime4kShaderEntry({
    required this.name,
    required this.size,
    required this.sha256,
  });

  final String name;
  final int size;
  final String sha256;
}

class Anime4kShaderManifest {
  Anime4kShaderManifest._(Iterable<Anime4kShaderEntry> entries)
    : entries = List<Anime4kShaderEntry>.unmodifiable(entries) {
    _byName = <String, Anime4kShaderEntry>{
      for (final entry in this.entries) entry.name: entry,
    };
  }

  static final Anime4kShaderManifest empty = Anime4kShaderManifest._(
    const <Anime4kShaderEntry>[],
  );

  final List<Anime4kShaderEntry> entries;
  late final Map<String, Anime4kShaderEntry> _byName;

  List<String> get names => List<String>.unmodifiable(
    entries.map((entry) => entry.name),
  );

  bool get isEmpty => entries.isEmpty;

  /// Stable key for an ordered shader pipeline.
  ///
  /// Shader order is part of Anime4K semantics, so the same files in a
  /// different order intentionally produce a different key. Unknown files
  /// fail closed: a Metal pipeline must never claim a cache identity for bytes
  /// that were not part of the manifest that was actually inspected.
  String pipelineHash(Iterable<String> orderedNames) {
    final buffer = StringBuffer('anime4k-pipeline-v1\n');
    var count = 0;
    for (final name in orderedNames) {
      final entry = _byName[name];
      if (entry == null) {
        throw ArgumentError.value(
          name,
          'orderedNames',
          'Shader is not present in the active Anime4K manifest',
        );
      }
      count += 1;
      // Length-prefix the filename so names containing separators cannot make
      // two distinct pipelines serialize to the same text accidentally.
      buffer
        ..write(name.length)
        ..write(':')
        ..write(name)
        ..write(':')
        ..write(entry.size)
        ..write(':')
        ..write(entry.sha256)
        ..write('\n');
    }
    if (count == 0) return '';
    return sha256.convert(utf8.encode(buffer.toString())).toString();
  }
}

class _FileFingerprint {
  const _FileFingerprint({
    required this.size,
    required this.modifiedMicros,
    required this.changedMicros,
  });

  factory _FileFingerprint.fromStat(FileStat stat) => _FileFingerprint(
    size: stat.size,
    modifiedMicros: stat.modified.microsecondsSinceEpoch,
    changedMicros: stat.changed.microsecondsSinceEpoch,
  );

  final int size;
  final int modifiedMicros;
  final int changedMicros;

  bool matches(FileStat stat) {
    return size == stat.size &&
        modifiedMicros == stat.modified.microsecondsSinceEpoch &&
        changedMicros == stat.changed.microsecondsSinceEpoch;
  }
}

class _CachedManifest {
  const _CachedManifest({
    required this.directoryModifiedMicros,
    required this.directoryChangedMicros,
    required this.files,
    required this.manifest,
  });

  final int directoryModifiedMicros;
  final int directoryChangedMicros;
  final Map<String, _FileFingerprint> files;
  final Anime4kShaderManifest manifest;

  bool directoryMatches(FileStat stat) {
    return directoryModifiedMicros == stat.modified.microsecondsSinceEpoch &&
        directoryChangedMicros == stat.changed.microsecondsSinceEpoch;
  }
}

class Anime4kShaderManifestCache {
  Anime4kShaderManifestCache();

  /// Process-wide cache shared by the player, preview, and downloader.
  static final Anime4kShaderManifestCache shared = Anime4kShaderManifestCache();

  final Map<String, _CachedManifest> _cache = <String, _CachedManifest>{};

  Future<Anime4kShaderManifest> load(String directory) async {
    final path = _normalized(directory);
    if (path == null) return Anime4kShaderManifest.empty;

    final folder = Directory(path);
    try {
      if (!await folder.exists()) {
        _cache.remove(path);
        return Anime4kShaderManifest.empty;
      }

      final directoryStat = await folder.stat();
      final cached = _cache[path];
      if (cached != null && cached.directoryMatches(directoryStat)) {
        if (await _knownFilesUnchanged(path, cached.files)) {
          return cached.manifest;
        }
      }

      return await _rebuild(path, folder);
    } on FileSystemException {
      _cache.remove(path);
      return Anime4kShaderManifest.empty;
    }
  }

  void invalidate(String directory) {
    final path = _normalized(directory);
    if (path != null) _cache.remove(path);
  }

  String? _normalized(String directory) {
    final trimmed = directory.trim();
    if (trimmed.isEmpty) return null;
    return p.normalize(p.absolute(trimmed));
  }

  Future<bool> _knownFilesUnchanged(
    String directory,
    Map<String, _FileFingerprint> expected,
  ) async {
    for (final item in expected.entries) {
      final file = File(p.join(directory, item.key));
      try {
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file || !item.value.matches(stat)) {
          return false;
        }
      } on FileSystemException {
        return false;
      }
    }
    return true;
  }

  Future<Anime4kShaderManifest> _rebuild(
    String path,
    Directory folder,
  ) async {
    final entries = <Anime4kShaderEntry>[];
    final fingerprints = <String, _FileFingerprint>{};

    await for (final entity in folder.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (p.extension(name).toLowerCase() != '.glsl') continue;

      final stat = await entity.stat();
      if (stat.type != FileSystemEntityType.file) continue;
      final bytes = await entity.readAsBytes();
      entries.add(
        Anime4kShaderEntry(
          name: name,
          size: bytes.length,
          sha256: sha256.convert(bytes).toString(),
        ),
      );
      fingerprints[name] = _FileFingerprint.fromStat(stat);
    }

    entries.sort((a, b) => a.name.compareTo(b.name));
    final manifest = Anime4kShaderManifest._(entries);
    final directoryStat = await folder.stat();
    _cache[path] = _CachedManifest(
      directoryModifiedMicros: directoryStat.modified.microsecondsSinceEpoch,
      directoryChangedMicros: directoryStat.changed.microsecondsSinceEpoch,
      files: Map<String, _FileFingerprint>.unmodifiable(fingerprints),
      manifest: manifest,
    );
    return manifest;
  }
}

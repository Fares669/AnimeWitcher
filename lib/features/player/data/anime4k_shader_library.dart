/// Reads the viewer's Anime4K folder and turns a mode into mpv's argument.
///
/// Kept apart from [resolveAnime4kChain], which decides *which* shaders a mode
/// needs and stays free of the filesystem so it can be reasoned about on its
/// own. This part only answers "what is actually in that folder" and "what is
/// the absolute path of each".
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'anime4k.dart';

part 'anime4k_shader_library.g.dart';

/// A resolved pipeline, ready to hand to mpv.
class Anime4kPipeline {
  const Anime4kPipeline({
    required this.value,
    required this.files,
    required this.missing,
  });

  const Anime4kPipeline.none()
    : value = '',
      files = const <String>[],
      missing = const <String>[];

  /// The `glsl-shaders` string, empty when nothing should run.
  final String value;

  /// The shader filenames chosen, in order — for showing the viewer what the
  /// mode actually resolved to on their machine.
  final List<String> files;

  /// Shaders the mode wanted that the folder does not have.
  final List<String> missing;

  bool get isEmpty => value.isEmpty;
}

class Anime4kShaderLibrary {
  const Anime4kShaderLibrary();

  /// The `.glsl` filenames directly inside [directory].
  ///
  /// An unreadable or missing folder is an empty list rather than an error:
  /// a viewer who moved their shaders should get the picture back with no
  /// shaders, not a player that refuses to start.
  Future<List<String>> listShaders(String directory) async {
    final path = directory.trim();
    if (path.isEmpty) return const <String>[];
    try {
      final folder = Directory(path);
      if (!await folder.exists()) return const <String>[];
      final names = <String>[];
      await for (final entry in folder.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        if (p.extension(name).toLowerCase() == '.glsl') names.add(name);
      }
      names.sort();
      return names;
    } catch (_) {
      return const <String>[];
    }
  }

  /// What mpv should run for [mode] given the folder the viewer chose.
  Future<Anime4kPipeline> pipeline({
    required Anime4kMode mode,
    required Anime4kQuality quality,
    required String directory,
  }) async {
    if (mode == Anime4kMode.off || directory.trim().isEmpty) {
      return const Anime4kPipeline.none();
    }
    final available = await listShaders(directory);
    final chain = resolveAnime4kChain(
      mode: mode,
      quality: quality,
      available: available,
    );
    if (chain.files.isEmpty) {
      return Anime4kPipeline(
        value: '',
        files: const <String>[],
        missing: chain.missing,
      );
    }
    final paths = chain.files
        .map((name) => p.join(directory.trim(), name))
        .toList(growable: false);
    return Anime4kPipeline(
      value: anime4kGlslShadersValue(paths, onWindows: Platform.isWindows),
      files: chain.files,
      missing: chain.missing,
    );
  }
}

@Riverpod(keepAlive: true)
Anime4kShaderLibrary anime4kShaderLibrary(Ref ref) {
  return const Anime4kShaderLibrary();
}

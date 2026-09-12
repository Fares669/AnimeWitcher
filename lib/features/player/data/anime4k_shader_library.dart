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
import 'anime4k_shader_manifest.dart';

part 'anime4k_shader_library.g.dart';

/// A resolved pipeline, ready to hand to mpv or identify in the Metal cache.
class Anime4kPipeline {
  const Anime4kPipeline({
    required this.value,
    required this.files,
    required this.missing,
    this.pipelineHash = '',
  });

  const Anime4kPipeline.none()
    : value = '',
      files = const <String>[],
      missing = const <String>[],
      pipelineHash = '';

  /// The `glsl-shaders` string, empty when nothing should run.
  final String value;

  /// The shader filenames chosen, in order — for showing the viewer what the
  /// mode actually resolved to on their machine.
  final List<String> files;

  /// Shaders the mode wanted that the folder does not have.
  final List<String> missing;

  /// Stable identity of the ordered shader bytes used by this pipeline.
  ///
  /// Future Metal pipeline compilation uses this as its cache key. It is empty
  /// whenever no pipeline is active.
  final String pipelineHash;

  bool get isEmpty => value.isEmpty;
}

class Anime4kShaderLibrary {
  const Anime4kShaderLibrary({Anime4kShaderManifestCache? manifestCache})
    : _manifestCacheOverride = manifestCache;

  final Anime4kShaderManifestCache? _manifestCacheOverride;

  Anime4kShaderManifestCache get _manifestCache =>
      _manifestCacheOverride ?? Anime4kShaderManifestCache.shared;

  /// The `.glsl` filenames directly inside [directory].
  ///
  /// The manifest cache avoids rereading every shader for repeated preview or
  /// apply operations. An unreadable or missing folder is an empty list rather
  /// than an error: a viewer who moved their shaders should get the picture
  /// back with no shaders, not a player that refuses to start.
  Future<List<String>> listShaders(String directory) async {
    final manifest = await _manifestCache.load(directory);
    return manifest.names;
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

    // Load once. Calling [listShaders] here would perform a second cache check
    // and leave the hash detached from the exact manifest used to resolve the
    // chain if the folder changed between those two calls.
    final manifest = await _manifestCache.load(directory);
    final chain = resolveAnime4kChain(
      mode: mode,
      quality: quality,
      available: manifest.names,
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
      pipelineHash: manifest.pipelineHash(chain.files),
    );
  }
}

@Riverpod(keepAlive: true)
Anime4kShaderLibrary anime4kShaderLibrary(Ref ref) {
  return const Anime4kShaderLibrary();
}

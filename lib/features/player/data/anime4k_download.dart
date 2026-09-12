/// Fetches the Anime4K shaders so nobody has to go and find them.
///
/// The shaders are a separate MIT-licensed project, not something this app
/// ships. Asking a viewer to download a zip, find the `.glsl` files inside it
/// and point a file picker at them is three steps too many for a feature
/// whose whole appeal is that it makes the picture better without thinking
/// about it. So the app fetches the official release itself, on request.
///
/// The release tag is pinned rather than tracking "latest": what gets
/// downloaded should be the set these pipelines were written against, and a
/// new release that renames or reshapes the files should be something a
/// person looks at, not something that lands silently on a viewer's machine.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/network/dio_client_provider.dart';
import 'anime4k_shader_manifest.dart';

part 'anime4k_download.g.dart';

/// The release this app was written against.
const String anime4kReleaseTag = 'v4.0.1';

/// The one asset that release carries — about 760 KB of GLSL.
const String anime4kDownloadUrl =
    'https://github.com/bloc97/Anime4K/releases/download/'
    '$anime4kReleaseTag/Anime4K_v4.0.zip';

/// Where the project lives, for crediting it in the interface.
const String anime4kProjectUrl = 'https://github.com/bloc97/Anime4K';

/// Integrity metadata for one shader in the pinned release.
///
/// [gitBlobSha1] is Git's content-addressed object id for the exact file bytes.
/// We use the same construction for the release-asset bytes so verification is
/// deterministic even where the release ZIP differs from the tagged Git tree.
class Anime4kExpectedShader {
  const Anime4kExpectedShader({
    required this.size,
    required this.gitBlobSha1,
  });

  final int size;
  final String gitBlobSha1;
}

/// The exact v4.0.1 release-asset shader subset used by AnimeWitcher's A/B/C
/// pipelines.
///
/// Most files are byte-identical to tag `v4.0.1`; the official ZIP's
/// Clamp_Highlights and AutoDownscalePre x2/x4 files are not. These values pin
/// the bytes from `Anime4K_v4.0.zip`, because that is the artifact this app
/// actually downloads. Apple CI re-downloads the official asset and verifies
/// every entry against this manifest before translating the corpus to Metal.
const Map<String, Anime4kExpectedShader> anime4kV401ExpectedManifest =
    <String, Anime4kExpectedShader>{
      'Anime4K_Clamp_Highlights.glsl': Anime4kExpectedShader(
        size: 2884,
        gitBlobSha1: '755130a8293c42835a2e28cf4ec14fed651a8b23',
      ),
      'Anime4K_Restore_CNN_S.glsl': Anime4kExpectedShader(
        size: 17136,
        gitBlobSha1: '209bfbb6bd31331b09a7090e91f65be6f8b68dcf',
      ),
      'Anime4K_Restore_CNN_M.glsl': Anime4kExpectedShader(
        size: 35916,
        gitBlobSha1: '7f5ea9d87da38b7db82a5e115c5fd0980ed72f5e',
      ),
      'Anime4K_Restore_CNN_L.glsl': Anime4kExpectedShader(
        size: 69921,
        gitBlobSha1: 'ab59a7cb96110ac87b15902a693b8bcd4dac9570',
      ),
      'Anime4K_Restore_CNN_VL.glsl': Anime4kExpectedShader(
        size: 144075,
        gitBlobSha1: '0810c8d5691f5ea4bfb6dcf85c02fdb703e2dbb6',
      ),
      'Anime4K_Restore_CNN_UL.glsl': Anime4kExpectedShader(
        size: 308660,
        gitBlobSha1: 'ca17027ce14119606c2a5ed917841a39dcc08b61',
      ),
      'Anime4K_Restore_CNN_Soft_S.glsl': Anime4kExpectedShader(
        size: 17198,
        gitBlobSha1: '8da70b580debd7f6a6f3abdf553821755cb33fcd',
      ),
      'Anime4K_Restore_CNN_Soft_M.glsl': Anime4kExpectedShader(
        size: 36016,
        gitBlobSha1: '2da72cb2bac3a62a53b7ccea51d0189e93eebaed',
      ),
      'Anime4K_Restore_CNN_Soft_L.glsl': Anime4kExpectedShader(
        size: 70020,
        gitBlobSha1: '355c77f2105fff10ffbc9c9edc361c5af2344494',
      ),
      'Anime4K_Restore_CNN_Soft_VL.glsl': Anime4kExpectedShader(
        size: 144204,
        gitBlobSha1: '74d4f4ca55e1901e5a8216af487be3ffd459f60a',
      ),
      'Anime4K_Restore_CNN_Soft_UL.glsl': Anime4kExpectedShader(
        size: 308873,
        gitBlobSha1: '0ac397c25a5a40ae6581dcd1553135b69239bcc8',
      ),
      'Anime4K_Upscale_CNN_x2_S.glsl': Anime4kExpectedShader(
        size: 18638,
        gitBlobSha1: 'e6ad7c218452014eaf70170cb5160e9ff427ffbe',
      ),
      'Anime4K_Upscale_CNN_x2_M.glsl': Anime4kExpectedShader(
        size: 37685,
        gitBlobSha1: '156c6bdd3b80a6c784ddf6655493bb35337cc0ec',
      ),
      'Anime4K_Upscale_CNN_x2_L.glsl': Anime4kExpectedShader(
        size: 73443,
        gitBlobSha1: '034de41f14e731c676124b78f74587d461abf14f',
      ),
      'Anime4K_Upscale_CNN_x2_VL.glsl': Anime4kExpectedShader(
        size: 146743,
        gitBlobSha1: 'c562e6e02d54b6313313ff5aa971dda9c4148676',
      ),
      'Anime4K_Upscale_CNN_x2_UL.glsl': Anime4kExpectedShader(
        size: 290257,
        gitBlobSha1: '1826b53926d7db0344dccb1e7dfcca4a10c3575a',
      ),
      'Anime4K_Upscale_Denoise_CNN_x2_S.glsl': Anime4kExpectedShader(
        size: 18667,
        gitBlobSha1: 'c1b4cb18f4db511f5ea9b34babd8d6ced72bed33',
      ),
      'Anime4K_Upscale_Denoise_CNN_x2_M.glsl': Anime4kExpectedShader(
        size: 37714,
        gitBlobSha1: '5076f5dd968ef854b48478f4547a411c811c37dc',
      ),
      'Anime4K_Upscale_Denoise_CNN_x2_L.glsl': Anime4kExpectedShader(
        size: 73584,
        gitBlobSha1: '2bf4b2ac453c549935643d11af91c18905fbfbf3',
      ),
      'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl': Anime4kExpectedShader(
        size: 146811,
        gitBlobSha1: 'ac122b9a14b36b42c233dee0f063183b234d5b39',
      ),
      'Anime4K_Upscale_Denoise_CNN_x2_UL.glsl': Anime4kExpectedShader(
        size: 290040,
        gitBlobSha1: '18c8453b0262c32347fd94c81791efb271a0a8b5',
      ),
      'Anime4K_AutoDownscalePre_x2.glsl': Anime4kExpectedShader(
        size: 1596,
        gitBlobSha1: 'd321b7d79a0922b4e219b30a65840646c6f5ff8d',
      ),
      'Anime4K_AutoDownscalePre_x4.glsl': Anime4kExpectedShader(
        size: 1604,
        gitBlobSha1: '7ffa64d0baf86ac27c769cb49f436fba68f717d7',
      ),
    };

/// The name to write an archive entry under, or null to skip it.
///
/// Only `.glsl` files are taken, and only ever under their bare filename.
/// That flattening is what the resolver expects — it matches on filenames,
/// not on the folders the release happens to group them into. The downloader
/// separately rejects traversal/absolute archive paths before calling this
/// helper, so flattening is never used as the security boundary.
String? anime4kExtractName(String entryName) {
  final trimmed = entryName.trim();
  if (trimmed.isEmpty) return null;
  // Zip entries always use forward slashes, whatever wrote them; Windows
  // archivers sometimes use backslashes anyway.
  final base = trimmed.split(RegExp(r'[/\\]')).last;
  if (base.isEmpty || base == '.' || base == '..') return null;
  if (p.extension(base).toLowerCase() != '.glsl') return null;
  if (base.contains(':')) return null;
  return base;
}

bool _unsafeArchivePath(String entryName) {
  final normalized = entryName.trim().replaceAll('\\', '/');
  if (normalized.isEmpty) return false;
  if (normalized.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    return true;
  }
  return normalized.split('/').contains('..');
}

String _gitBlobSha1(List<int> bytes) {
  final header = utf8.encode('blob ${bytes.length}\u0000');
  return sha1.convert(<int>[...header, ...bytes]).toString();
}

/// What a download did.
class Anime4kDownloadResult {
  const Anime4kDownloadResult({required this.directory, required this.written});

  /// Where the shaders now are, ready to be handed to the settings.
  final String directory;

  /// How many verified shader files were activated.
  final int written;
}

class Anime4kDownloadException implements Exception {
  const Anime4kDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Anime4kDownloader {
  const Anime4kDownloader(
    this._dio, {
    Map<String, Anime4kExpectedShader>? expectedManifest,
  }) : _expectedManifestOverride = expectedManifest;

  final Dio _dio;
  final Map<String, Anime4kExpectedShader>? _expectedManifestOverride;

  Map<String, Anime4kExpectedShader> get _expectedManifest =>
      _expectedManifestOverride ?? anime4kV401ExpectedManifest;

  /// The folder the app keeps downloaded shaders in.
  ///
  /// Application support rather than documents: these are not the viewer's
  /// files to manage, and nothing else should be tidying them away.
  static Future<Directory> defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'anime4k_shaders'));
  }

  /// Downloads, verifies, and atomically activates the pinned release.
  ///
  /// Extraction happens in a temporary sibling directory. The active shader
  /// folder is replaced only after every expected shader has the exact pinned
  /// byte size and Git blob id. A failed download, malformed archive, integrity
  /// mismatch, duplicate, or activation error leaves the previous active set
  /// untouched whenever the filesystem permits the rollback.
  Future<Anime4kDownloadResult> download({
    Directory? into,
    void Function(double? progress)? onProgress,
  }) async {
    final target = into ?? await defaultDirectory();

    final Uint8List bytes;
    try {
      final response = await _dio.get<List<int>>(
        anime4kDownloadUrl,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(minutes: 2),
        ),
        onReceiveProgress: (received, total) {
          onProgress?.call(total > 0 ? received / total : null);
        },
      );
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw const Anime4kDownloadException('The download came back empty.');
      }
      bytes = Uint8List.fromList(data);
    } on DioException catch (error) {
      throw Anime4kDownloadException(
        'Could not reach the Anime4K release: ${error.message ?? error.type}',
      );
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const Anime4kDownloadException(
        'The downloaded file is not a readable archive.',
      );
    }

    final expected = _expectedManifest;
    if (expected.isEmpty) {
      throw const Anime4kDownloadException(
        'The Anime4K integrity manifest is empty.',
      );
    }

    final parent = target.parent;
    await parent.create(recursive: true);
    final staging = await parent.createTemp(
      '.${p.basename(target.path)}.staging-',
    );

    try {
      final written = await _extractVerified(
        archive: archive,
        staging: staging,
        expected: expected,
      );
      await _activateAtomically(staging: staging, target: target);
      Anime4kShaderManifestCache.shared.invalidate(target.path);
      return Anime4kDownloadResult(directory: target.path, written: written);
    } on Anime4kDownloadException {
      rethrow;
    } catch (error) {
      throw Anime4kDownloadException(
        'Could not safely install the Anime4K shaders: $error',
      );
    } finally {
      try {
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } catch (_) {
        // Best-effort cleanup only. Never hide the original download result.
      }
    }
  }

  Future<int> _extractVerified({
    required Archive archive,
    required Directory staging,
    required Map<String, Anime4kExpectedShader> expected,
  }) async {
    final expectedByLower = <String, MapEntry<String, Anime4kExpectedShader>>{
      for (final item in expected.entries) item.key.toLowerCase(): item,
    };
    if (expectedByLower.length != expected.length) {
      throw const Anime4kDownloadException(
        'The Anime4K integrity manifest contains duplicate filenames.',
      );
    }

    final seenArchiveNames = <String>{};
    final written = <String>{};

    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (_unsafeArchivePath(entry.name)) {
        throw Anime4kDownloadException(
          'The Anime4K archive contains an unsafe path: ${entry.name}',
        );
      }

      final extractedName = anime4kExtractName(entry.name);
      if (extractedName == null) continue;
      final normalizedName = extractedName.toLowerCase();
      if (!seenArchiveNames.add(normalizedName)) {
        throw Anime4kDownloadException(
          'The Anime4K archive contains duplicate shader: $extractedName',
        );
      }

      final required = expectedByLower[normalizedName];
      if (required == null) {
        // Keep the activated set minimal and deterministic: only shaders the
        // app can actually resolve are installed.
        continue;
      }

      final content = entry.readBytes();
      if (content == null || content.isEmpty) {
        throw Anime4kDownloadException(
          'Anime4K shader ${required.key} is empty.',
        );
      }
      final expectedShader = required.value;
      if (content.length != expectedShader.size ||
          _gitBlobSha1(content) != expectedShader.gitBlobSha1) {
        throw Anime4kDownloadException(
          'Anime4K shader ${required.key} failed integrity verification.',
        );
      }

      await File(
        p.join(staging.path, required.key),
      ).writeAsBytes(content, flush: true);
      written.add(required.key);
    }

    if (written.length != expected.length) {
      final missing = expected.keys.where((name) => !written.contains(name));
      throw Anime4kDownloadException(
        'The Anime4K archive is incomplete; missing: ${missing.join(', ')}',
      );
    }
    return written.length;
  }

  Future<void> _activateAtomically({
    required Directory staging,
    required Directory target,
  }) async {
    final backup = Directory('${staging.path}.previous');
    var movedPrevious = false;

    try {
      if (await target.exists()) {
        await target.rename(backup.path);
        movedPrevious = true;
      }
      await staging.rename(target.path);
    } catch (error) {
      if (movedPrevious &&
          !await target.exists() &&
          await backup.exists()) {
        try {
          await backup.rename(target.path);
        } catch (_) {
          // Preserve the backup for manual recovery if rollback itself fails.
        }
      }
      throw Anime4kDownloadException(
        'Could not activate the verified Anime4K shader set: $error',
      );
    }

    // Activation already succeeded. A stale backup is preferable to turning a
    // successful verified install into an application-visible failure.
    try {
      if (await backup.exists()) {
        await backup.delete(recursive: true);
      }
    } catch (_) {
      // Best effort.
    }
  }
}

@Riverpod(keepAlive: true)
Anime4kDownloader anime4kDownloader(Ref ref) {
  return Anime4kDownloader(ref.watch(dioClientProvider));
}

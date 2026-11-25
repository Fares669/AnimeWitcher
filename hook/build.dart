import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:code_assets/code_assets.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // The hook is also invoked when code assets are not being built, and
    // reading input.config.code in that case throws, which fails the whole
    // build rather than skipping the native library.
    if (!input.config.buildCodeAssets) return;

    final builder = CBuilder.library(
      name: 'subsampling_scale_image_view',
      assetName: 'subsampling_scale_image_view.dart',
      sources: ['lib/ffi/image_decoder.cpp'],
      includes: ['lib/ffi/'],
      flags: [
        if (input.config.code.targetOS == OS.iOS ||
            input.config.code.targetOS == OS.macOS) ...[
          '-framework',
          'CoreFoundation',
          '-framework',
          'CoreGraphics',
          '-framework',
          'ImageIO',
        ],
      ],
    );

    await builder.run(input: input, output: output);
    if (input.userDefines['rust_download_sha256'] == true &&
        Abi.current() == Abi.linuxX64 &&
        input.config.code.targetOS == OS.linux &&
        input.config.code.targetArchitecture == Architecture.x64) {
      await _buildDownloadDigest(input, output);
    }
  });
}

Future<void> _buildDownloadDigest(
  BuildInput input,
  BuildOutputBuilder output,
) async {
  final source = input.packageRoot.resolve('native/download_sha256/');
  final target = input.outputDirectoryShared.resolve('download_sha256/');
  final result = await Process.run('cargo', [
    'build',
    '--locked',
    '--release',
    '--lib',
    '--target',
    'x86_64-unknown-linux-gnu',
    '--target-dir',
    target.toFilePath(),
  ], workingDirectory: source.toFilePath());
  if (result.exitCode != 0) {
    throw StateError(
      'Cargo could not build the download digest: ${result.stderr}',
    );
  }
  const name = 'libanimewitcher_download_sha256.so';
  final library = target.resolve('x86_64-unknown-linux-gnu/release/$name');
  final packaged = input.outputDirectory.resolve(name);
  await File.fromUri(library).copy(packaged.toFilePath());
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'core/utils/download_file_digest.dart',
      linkMode: DynamicLoadingBundled(),
      file: packaged,
    ),
  );
  for (final file in ['Cargo.toml', 'Cargo.lock', 'src/lib.rs']) {
    output.dependencies.add(source.resolve(file));
  }
}

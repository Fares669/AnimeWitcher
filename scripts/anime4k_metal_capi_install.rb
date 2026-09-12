# frozen_string_literal: true

require 'fileutils'

# Installs the Dart-facing C API next to the other Anime4K Swift support files
# copied into media_kit_video by the render-path patch.
def install_anime4k_metal_capi(plugin_root:, native_dir:, platform:)
  plugin_dir = anime4k_media_kit_plugin_dir(
    plugin_root: plugin_root,
    platform: platform
  )
  source = File.join(native_dir, 'Anime4KMetalCAPI.swift')
  raise Anime4KMediaKitPatchError, "Anime4K Metal C API missing: #{source}" unless File.file?(source)

  destination_dir = File.join(plugin_dir, 'anime4k')
  FileUtils.mkdir_p(destination_dir)
  FileUtils.cp(source, File.join(destination_dir, 'Anime4KMetalCAPI.swift'))
end

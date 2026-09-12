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


ANIME4K_METAL_CAPI_SYMBOLS = %w[
  animewitcher_anime4k_metal_configure
  animewitcher_anime4k_metal_status
  animewitcher_anime4k_metal_telemetry
  animewitcher_anime4k_metal_set_bypass
  animewitcher_anime4k_metal_disable
].freeze

def retain_anime4k_metal_capi_symbols(target)
  return unless target.name == 'media_kit_video'

  retention_flags = ANIME4K_METAL_CAPI_SYMBOLS.map do |symbol|
    "-Wl,-u,_#{symbol}"
  end
  target.build_configurations.each do |configuration|
    current = configuration.build_settings['OTHER_LDFLAGS']
    flags = case current
            when Array
              current.dup
            when nil
              ['$(inherited)']
            else
              [current]
            end
    retention_flags.each { |flag| flags << flag unless flags.include?(flag) }
    configuration.build_settings['OTHER_LDFLAGS'] = flags
  end
end

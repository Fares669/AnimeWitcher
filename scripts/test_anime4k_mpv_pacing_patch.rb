# frozen_string_literal: true

require 'tmpdir'
require_relative 'test_anime4k_media_kit_patch'
require_relative 'anime4k_mpv_pacing_patch'

Dir.mktmpdir('anime4k-mpv-pacing') do |root|
  package_root, native = build_package_fixture(root)
  plugin = source_plugin_dir(package_root, :ios)
  texture = File.join(plugin, 'TextureHW.swift')

  patch_anime4k_media_kit_video(
    plugin_root: package_root,
    native_dir: native,
    platform: :ios
  )
  patch_anime4k_mpv_render_pacing(
    plugin_root: package_root,
    platform: :ios
  )

  patched = File.read(texture)
  assert(
    patched.scan('AnimeWitcherNonBlockingMPVRender').length == 1,
    'pacing marker must be inserted exactly once'
  )
  assert(
    patched.include?('MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME'),
    'Metal render must disable mpv target-time blocking'
  )
  assert(
    patched.include?('anime4kBlockForTargetTime: CInt = 0'),
    'Metal render must request non-blocking mpv timing'
  )
  assert(
    patched.include?('anime4kFrameInfo.target_time'),
    'pacing integration must preserve mpv target presentation time'
  )
  assert(
    patched.include?('mpv_get_time_us(strongSelf.handle)'),
    'publication must compare against mpv clock after Metal completes'
  )
  assert(
    patched.include?('anime4kDelayUs'),
    'publication must wait only for remaining target-time headroom'
  )
  assert(
    patched.match?(/else \{\n\s+mpv_render_context_render\(renderContext, &params\)\n\s+\}/),
    'non-Metal rendering must preserve media_kit mpv timing behavior'
  )

  first = File.read(texture)
  patch_anime4k_mpv_render_pacing(
    plugin_root: package_root,
    platform: :ios
  )
  assert(File.read(texture) == first, 'pacing patch must be idempotent')
end

puts 'Anime4KMpvPacingPatchTests: PASS'

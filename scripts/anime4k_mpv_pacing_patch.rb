# frozen_string_literal: true

require_relative 'anime4k_media_kit_patch'

class Anime4KMpvPacingPatchError < StandardError; end

ANIME4K_MPV_PACING_MARKER = 'AnimeWitcherNonBlockingMPVRender'

def anime4k_pacing_replace_once(source, needle, replacement, label)
  count = source.scan(Regexp.new(Regexp.escape(needle))).length
  unless count == 1
    raise Anime4KMpvPacingPatchError,
          "#{label}: expected exactly one match, found #{count}"
  end
  source.sub(needle, replacement)
end

def patch_anime4k_mpv_render_pacing(plugin_root:, platform:)
  plugin_dir = anime4k_media_kit_plugin_dir(
    plugin_root: plugin_root,
    platform: platform
  )
  texture_path = File.join(plugin_dir, 'TextureHW.swift')
  source = File.read(texture_path)

  # This patch intentionally composes after anime4k_media_kit_patch.rb. The
  # first patch makes TextureHW asynchronous; this one moves the expensive
  # Anime4K GPU work into mpv's render-ahead window while retaining mpv's
  # target presentation time for A/V sync.
  return if source.include?(ANIME4K_MPV_PACING_MARKER)

  condition_needle =
    "        if Anime4KMediaKitBridge.shared.runtimeStatus(handle: handle) == .ready {\n"
  condition_replacement = <<~'SWIFT'.lines.map { |line| "        #{line}" }.join
    let anime4kMetalReady =
      Anime4KMediaKitBridge.shared.runtimeStatus(handle: handle) == .ready
    var anime4kTargetTime: Int64 = 0
    if anime4kMetalReady {
  SWIFT
  source = anime4k_pacing_replace_once(
    source,
    condition_needle,
    condition_replacement,
    'Anime4K Metal-ready render marker'
  )

  frame_info_needle = <<~'SWIFT'.lines.map { |line| "          #{line}" }.join
    let anime4kHasFrame = anime4kFrameInfo.flags &
      UInt64(MPV_RENDER_FRAME_INFO_PRESENT.rawValue) != 0
  SWIFT
  frame_info_replacement = <<~'SWIFT'.lines.map { |line| "          #{line}" }.join
    if anime4kFrameInfoResult >= 0 {
      anime4kTargetTime = anime4kFrameInfo.target_time
    }
    let anime4kHasFrame = anime4kFrameInfo.flags &
      UInt64(MPV_RENDER_FRAME_INFO_PRESENT.rawValue) != 0
  SWIFT
  source = anime4k_pacing_replace_once(
    source,
    frame_info_needle,
    frame_info_replacement,
    'mpv next-frame target-time marker'
  )

  render_needle = "    mpv_render_context_render(renderContext, &params)\n"
  render_replacement = <<~'SWIFT'.lines.map { |line| "    #{line}" }.join
    // AnimeWitcherNonBlockingMPVRender
    if anime4kMetalReady {
      // mpv normally waits here until target_time. Anime4K would then start
      // ~25 ms too late. Render ahead instead and preserve the target below.
      var anime4kBlockForTargetTime: CInt = 0
      withUnsafeMutablePointer(to: &anime4kBlockForTargetTime) { pointer in
        var anime4kParameters = params
        anime4kParameters.insert(
          mpv_render_param(
            type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,
            data: UnsafeMutableRawPointer(pointer)
          ),
          at: max(0, anime4kParameters.count - 1)
        )
        mpv_render_context_render(renderContext, &anime4kParameters)
      }
    } else {
      mpv_render_context_render(renderContext, &params)
    }
  SWIFT
  source = anime4k_pacing_replace_once(
    source,
    render_needle,
    render_replacement,
    'mpv render call marker'
  )

  publish_needle = <<~'SWIFT'.lines.map { |line| "          #{line}" }.join
    strongSelf.textureContexts.pushAsReady(textureContext!)
    completion()
  SWIFT
  publish_replacement = <<~'SWIFT'.lines.map { |line| "          #{line}" }.join
    let anime4kPublish = {
      strongSelf.textureContexts.pushAsReady(textureContext!)
      completion()
    }
    let anime4kNow = mpv_get_time_us(strongSelf.handle)
    let anime4kDelayUs = anime4kTargetTime > anime4kNow
      ? anime4kTargetTime - anime4kNow
      : 0
    if anime4kDelayUs > 0 {
      DispatchQueue.main.asyncAfter(
        deadline: .now() + .microseconds(Int(anime4kDelayUs)),
        execute: anime4kPublish
      )
    } else {
      anime4kPublish()
    }
  SWIFT
  source = anime4k_pacing_replace_once(
    source,
    publish_needle,
    publish_replacement,
    'Anime4K publication marker'
  )

  File.write(texture_path, source)
end

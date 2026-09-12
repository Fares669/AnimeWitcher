# frozen_string_literal: true

require_relative 'anime4k_media_kit_patch'

class Anime4KMpvPacingPatchError < StandardError; end

ANIME4K_MPV_PACING_MARKER = 'AnimeWitcherNonBlockingMPVRender'

def anime4k_pacing_replace_pattern_once(source, pattern, label)
  count = source.scan(pattern).length
  unless count == 1
    raise Anime4KMpvPacingPatchError,
          "#{label}: expected exactly one match, found #{count}"
  end

  match = source.match(pattern)
  source.sub(pattern, yield(match))
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

  condition_pattern =
    /^([ \t]*)if Anime4KMediaKitBridge\.shared\.runtimeStatus\(handle: handle\) == \.ready \{\n/
  source = anime4k_pacing_replace_pattern_once(
    source,
    condition_pattern,
    'Anime4K Metal-ready render marker'
  ) do |match|
    indent = match[1]
    "#{indent}let anime4kMetalReady =\n" \
      "#{indent}  Anime4KMediaKitBridge.shared.runtimeStatus(handle: handle) == .ready\n" \
      "#{indent}var anime4kTargetTime: Int64 = 0\n" \
      "#{indent}if anime4kMetalReady {\n"
  end

  frame_info_pattern =
    /^([ \t]*)let anime4kHasFrame = anime4kFrameInfo\.flags &\n[ \t]*UInt64\(MPV_RENDER_FRAME_INFO_PRESENT\.rawValue\) != 0\n/
  source = anime4k_pacing_replace_pattern_once(
    source,
    frame_info_pattern,
    'mpv next-frame target-time marker'
  ) do |match|
    indent = match[1]
    "#{indent}if anime4kFrameInfoResult >= 0 {\n" \
      "#{indent}  anime4kTargetTime = anime4kFrameInfo.target_time\n" \
      "#{indent}}\n" \
      "#{indent}let anime4kHasFrame = anime4kFrameInfo.flags &\n" \
      "#{indent}  UInt64(MPV_RENDER_FRAME_INFO_PRESENT.rawValue) != 0\n"
  end

  render_pattern =
    /^([ \t]*)mpv_render_context_render\(renderContext, &params\)\n/
  source = anime4k_pacing_replace_pattern_once(
    source,
    render_pattern,
    'mpv render call marker'
  ) do |match|
    indent = match[1]
    "#{indent}// AnimeWitcherNonBlockingMPVRender\n" \
      "#{indent}if anime4kMetalReady {\n" \
      "#{indent}  // mpv normally waits here until target_time. Anime4K would then start\n" \
      "#{indent}  // ~25 ms too late. Render ahead instead and preserve the target below.\n" \
      "#{indent}  var anime4kBlockForTargetTime: CInt = 0\n" \
      "#{indent}  withUnsafeMutablePointer(to: &anime4kBlockForTargetTime) { pointer in\n" \
      "#{indent}    var anime4kParameters = params\n" \
      "#{indent}    anime4kParameters.insert(\n" \
      "#{indent}      mpv_render_param(\n" \
      "#{indent}        type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,\n" \
      "#{indent}        data: UnsafeMutableRawPointer(pointer)\n" \
      "#{indent}      ),\n" \
      "#{indent}      at: max(0, anime4kParameters.count - 1)\n" \
      "#{indent}    )\n" \
      "#{indent}    mpv_render_context_render(renderContext, &anime4kParameters)\n" \
      "#{indent}  }\n" \
      "#{indent}} else {\n" \
      "#{indent}  mpv_render_context_render(renderContext, &params)\n" \
      "#{indent}}\n"
  end

  publish_pattern =
    /^([ \t]*)strongSelf\.textureContexts\.pushAsReady\(textureContext!\)\n[ \t]*completion\(\)\n/
  source = anime4k_pacing_replace_pattern_once(
    source,
    publish_pattern,
    'Anime4K publication marker'
  ) do |match|
    indent = match[1]
    "#{indent}let anime4kPublish = {\n" \
      "#{indent}  strongSelf.textureContexts.pushAsReady(textureContext!)\n" \
      "#{indent}  completion()\n" \
      "#{indent}}\n" \
      "#{indent}let anime4kNow = mpv_get_time_us(strongSelf.handle)\n" \
      "#{indent}let anime4kDelayUs = anime4kTargetTime > anime4kNow\n" \
      "#{indent}  ? anime4kTargetTime - anime4kNow\n" \
      "#{indent}  : 0\n" \
      "#{indent}if anime4kDelayUs > 0 {\n" \
      "#{indent}  DispatchQueue.main.asyncAfter(\n" \
      "#{indent}    deadline: .now() + .microseconds(Int(anime4kDelayUs)),\n" \
      "#{indent}    execute: anime4kPublish\n" \
      "#{indent}  )\n" \
      "#{indent}} else {\n" \
      "#{indent}  anime4kPublish()\n" \
      "#{indent}}\n"
  end

  File.write(texture_path, source)
end

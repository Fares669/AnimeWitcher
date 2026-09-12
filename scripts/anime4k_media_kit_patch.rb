# frozen_string_literal: true

require 'fileutils'

class Anime4KMediaKitPatchError < StandardError; end

ANIME4K_MEDIA_KIT_SUPPORT_FILES = %w[
  Anime4KMetalShader.swift
  Anime4KMetalRuntime.swift
  Anime4KMediaKitBridge.swift
].freeze

def anime4k_sync_support_files(plugin_dir:, native_dir:)
  destination = File.join(plugin_dir, 'anime4k')
  FileUtils.mkdir_p(destination)

  ANIME4K_MEDIA_KIT_SUPPORT_FILES.each do |name|
    source = File.join(native_dir, name)
    unless File.file?(source)
      raise Anime4KMediaKitPatchError, "Anime4K native support file missing: #{source}"
    end
    FileUtils.cp(source, File.join(destination, name))
  end
end

def patch_anime4k_media_kit_video(plugin_dir:, native_dir:, platform:)
  unless %i[ios macos].include?(platform)
    raise Anime4KMediaKitPatchError, "unsupported Apple media_kit platform: #{platform}"
  end

  files = {
    texture: File.join(plugin_dir, 'TextureHW.swift'),
    protocol: File.join(plugin_dir, 'common', 'ResizableTextureProtocol.swift'),
    safe: File.join(plugin_dir, 'common', 'SafeResizableTexture.swift'),
    video: File.join(plugin_dir, 'common', 'VideoOutput.swift')
  }
  files.each_value do |path|
    raise Anime4KMediaKitPatchError, "media_kit source missing: #{path}" unless File.file?(path)
  end

  sources = files.transform_values { |path| File.read(path) }
  markers = {
    texture: 'AnimeWitcherAnime4KMetalRenderHook',
    protocol: 'AnimeWitcherAnime4KCompletionProtocol',
    safe: 'AnimeWitcherAnime4KCompletionForwarding',
    video: 'AnimeWitcherAnime4KCompletionPublication'
  }
  marker_state = {}
  markers.each { |key, marker| marker_state[key] = sources[key].include?(marker) }
  marked = marker_state.values.count(true)
  if marked.positive? && marked != markers.length
    raise Anime4KMediaKitPatchError, 'media_kit Anime4K patch is partially applied; clean Pods and retry'
  end
  if marked == markers.length
    anime4k_sync_support_files(plugin_dir: plugin_dir, native_dir: native_dir)
    return
  end

  texture_signature = "  public func render(_ size: CGSize) {\n"
  unless sources[:texture].scan(texture_signature).length == 1
    raise Anime4KMediaKitPatchError, 'media_kit TextureHW render marker changed'
  end
  texture_tail = "    glFlush()\n\n    textureContexts.pushAsReady(textureContext!)\n"
  unless sources[:texture].scan(texture_tail).length == 1
    raise Anime4KMediaKitPatchError, 'media_kit TextureHW publish marker changed'
  end

  protocol_needle = "  func render(_ size: CGSize)\n}"
  unless sources[:protocol].scan(protocol_needle).length == 1
    raise Anime4KMediaKitPatchError, 'media_kit ResizableTextureProtocol marker changed'
  end

  safe_match = sources[:safe].match(/  public func render\(_ size: CGSize\) \{\n.*?^  \}\n/m)
  unless safe_match && safe_match[0].include?('child.render(size)') && safe_match[0].include?('locked')
    raise Anime4KMediaKitPatchError, 'media_kit SafeResizableTexture render marker changed'
  end

  video_needle = <<~'SWIFT'.lines.map { |line| "    #{line}" }.join
    texture.render(size)
    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      // Textures must be marked as available from the main thread
      that.registry.textureFrameAvailable(that.textureId)
    }
  SWIFT
  unless sources[:video].scan(video_needle).length == 1
    raise Anime4KMediaKitPatchError, 'media_kit VideoOutput publication marker changed'
  end

  texture = sources[:texture].sub(
    texture_signature,
    <<~'SWIFT'.lines.map { |line| "  #{line}" }.join
      public func render(_ size: CGSize) {
        render(size, completion: {})
      }

      public func render(
        _ size: CGSize,
        completion: @escaping () -> Void
      ) {
    SWIFT
  )
  texture = texture.sub(
    "    if textureContext == nil {\n      return\n    }\n",
    "    if textureContext == nil {\n      completion()\n      return\n    }\n"
  )
  texture = texture.sub(
    texture_tail,
    <<~'SWIFT'.lines.map { |line| "    #{line}" }.join
      glFlush()

      // AnimeWitcherAnime4KMetalRenderHook
      if Anime4KMediaKitBridge.shared.process(
        handle: handle,
        pixelBuffer: textureContext!.pixelBuffer,
        completion: { [weak self] in
          guard let strongSelf = self else {
            completion()
            return
          }
          strongSelf.textureContexts.pushAsReady(textureContext!)
          completion()
        }
      ) {
        return
      }

      textureContexts.pushAsReady(textureContext!)
      completion()
    SWIFT
  )

  protocol_source = sources[:protocol].sub(
    protocol_needle,
    <<~'SWIFT'.chomp
      func render(_ size: CGSize)
      // AnimeWitcherAnime4KCompletionProtocol
      func render(_ size: CGSize, completion: @escaping () -> Void)
    }

    public extension ResizableTextureProtocol {
      func render(_ size: CGSize, completion: @escaping () -> Void) {
        render(size)
        completion()
      }
    }
    SWIFT
  )

  safe_source = sources[:safe].sub(
    safe_match[0],
    safe_match[0] + <<~'SWIFT'

      // AnimeWitcherAnime4KCompletionForwarding
      public func render(_ size: CGSize, completion: @escaping () -> Void) {
        return locked {
          return child.render(size, completion: completion)
        }
      }
    SWIFT
  )

  video_source = sources[:video].sub(
    video_needle,
    <<~'SWIFT'.lines.map { |line| "    #{line}" }.join
      // AnimeWitcherAnime4KCompletionPublication
      texture.render(size) { [weak self] in
        DispatchQueue.main.async {
          guard let that = self else { return }
          that.registry.textureFrameAvailable(that.textureId)
        }
      }
    SWIFT
  )

  anime4k_sync_support_files(plugin_dir: plugin_dir, native_dir: native_dir)
  File.write(files[:texture], texture)
  File.write(files[:protocol], protocol_source)
  File.write(files[:safe], safe_source)
  File.write(files[:video], video_source)
end

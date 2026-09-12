# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'anime4k_media_kit_patch'

TEXTURE_FIXTURE = <<~'SWIFT'
  import Flutter
  import OpenGLES

  public class TextureHW: NSObject, FlutterTexture, ResizableTextureProtocol {
    private let handle: OpaquePointer
    private var textureContexts = SwappableObjectManager<TextureGLESContext>(objects: [])

    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? { return nil }

    public func render(_ size: CGSize) {
      let textureContext = textureContexts.nextAvailable()
      if textureContext == nil { return }
      mpv_render_context_render(renderContext, &params)
      glFlush()

      textureContexts.pushAsReady(textureContext!)
    }
  }
SWIFT

PROTOCOL_FIXTURE = <<~'SWIFT'
  public protocol ResizableTextureProtocol: NSObject, FlutterTexture {
    func resize(_ size: CGSize)
    func render(_ size: CGSize)
  }
SWIFT

SAFE_FIXTURE = <<~'SWIFT'
  public class SafeResizableTexture: NSObject, FlutterTexture, ResizableTextureProtocol {
    private let lock = NSRecursiveLock()
    private let child: ResizableTextureProtocol

    public func render(_ size: CGSize) {
      return locked { return child.render(size) }
    }

    private func locked<T>(do block: () -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return block()
    }
  }
SWIFT

VIDEO_OUTPUT_FIXTURE = <<~'SWIFT'
  public class VideoOutput: NSObject {
    private var texture: ResizableTextureProtocol!
    private let registry: FlutterTextureRegistry
    private var textureId: Int64 = -1

    private func _updateCallback() {
      let size = videoSize
      if disposed { return }

      texture.render(size)
      DispatchQueue.main.sync { [weak self] in
        guard let that = self else { return }
        // Textures must be marked as available from the main thread
        that.registry.textureFrameAvailable(that.textureId)
      }
    }
  }
SWIFT

NATIVE_FILES = %w[
  Anime4KMetalShader.swift
  Anime4KMetalRuntime.swift
  Anime4KMediaKitBridge.swift
].freeze

def assert(condition, message)
  raise "ASSERTION FAILED: #{message}" unless condition
end

def build_fixture(root)
  plugin = File.join(root, 'plugin')
  common = File.join(plugin, 'common')
  native = File.join(root, 'native')
  FileUtils.mkdir_p(common)
  FileUtils.mkdir_p(native)
  File.write(File.join(plugin, 'TextureHW.swift'), TEXTURE_FIXTURE)
  File.write(File.join(common, 'ResizableTextureProtocol.swift'), PROTOCOL_FIXTURE)
  File.write(File.join(common, 'SafeResizableTexture.swift'), SAFE_FIXTURE)
  File.write(File.join(common, 'VideoOutput.swift'), VIDEO_OUTPUT_FIXTURE)
  NATIVE_FILES.each { |name| File.write(File.join(native, name), "// #{name}\n") }
  [plugin, native]
end

Dir.mktmpdir('anime4k-media-kit-patch') do |root|
  plugin, native = build_fixture(root)
  texture = File.join(plugin, 'TextureHW.swift')
  protocol = File.join(plugin, 'common', 'ResizableTextureProtocol.swift')
  safe = File.join(plugin, 'common', 'SafeResizableTexture.swift')
  video = File.join(plugin, 'common', 'VideoOutput.swift')

  patch_anime4k_media_kit_video(plugin_dir: plugin, native_dir: native, platform: :ios)

  patched = File.read(texture)
  marker = 'AnimeWitcherAnime4KMetalRenderHook'
  assert(patched.scan(marker).length == 1, 'render marker must be inserted once')
  assert(patched.index('glFlush()') < patched.index(marker), 'Metal hook must run after OpenGL flush')
  assert(patched.index(marker) < patched.index('textureContexts.pushAsReady'), 'Metal hook must run before media_kit publishes the buffer')
  assert(patched.include?('Anime4KMediaKitBridge.shared.process'), 'render hook must call the shared bridge')
  assert(patched.include?('completion()'), 'TextureHW must complete frame publication only after Metal/bypass')

  protocol_source = File.read(protocol)
  assert(protocol_source.include?('completion: @escaping () -> Void'), 'protocol must expose frame-completion rendering')

  safe_source = File.read(safe)
  assert(safe_source.include?('child.render(size, completion: completion)'), 'safe wrapper must forward completion rendering')

  video_source = File.read(video)
  async_render = video_source.index('texture.render(size) {')
  frame_available = video_source.index('registry.textureFrameAvailable')
  assert(async_render && frame_available && async_render < frame_available, 'VideoOutput must publish only from render completion')
  assert(!video_source.include?("texture.render(size)\n      DispatchQueue.main.sync"), 'old immediate publication path must be removed')

  copied = NATIVE_FILES.map { |name| File.join(plugin, 'anime4k', name) }
  copied.each { |path| assert(File.file?(path), "native support missing: #{path}") }

  first = [texture, protocol, safe, video].to_h { |path| [path, File.read(path)] }
  patch_anime4k_media_kit_video(plugin_dir: plugin, native_dir: native, platform: :ios)
  first.each { |path, contents| assert(File.read(path) == contents, "patch must be idempotent: #{path}") }
end

Dir.mktmpdir('anime4k-media-kit-drift') do |root|
  plugin, native = build_fixture(root)
  texture = File.join(plugin, 'TextureHW.swift')
  File.write(texture, TEXTURE_FIXTURE.sub("glFlush()\n\n", "glFlush()\n    // upstream changed\n"))

  begin
    patch_anime4k_media_kit_video(plugin_dir: plugin, native_dir: native, platform: :ios)
    raise 'ASSERTION FAILED: source drift must fail loudly'
  rescue Anime4KMediaKitPatchError => error
    assert(error.message.include?('marker changed'), 'drift error should identify the marker')
  end
end

puts 'Anime4KMediaKitPatchTests: PASS'

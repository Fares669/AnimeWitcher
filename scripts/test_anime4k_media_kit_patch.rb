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

def plugin_dir(package_root, platform)
  File.join(
    package_root,
    platform.to_s,
    'media_kit_video',
    'Sources',
    'media_kit_video',
    'plugin'
  )
end

def write_plugin_fixture(directory)
  common = File.join(directory, 'common')
  FileUtils.mkdir_p(common)
  File.write(File.join(directory, 'TextureHW.swift'), TEXTURE_FIXTURE)
  File.write(File.join(common, 'ResizableTextureProtocol.swift'), PROTOCOL_FIXTURE)
  File.write(File.join(common, 'SafeResizableTexture.swift'), SAFE_FIXTURE)
  File.write(File.join(common, 'VideoOutput.swift'), VIDEO_OUTPUT_FIXTURE)
end

def build_package_fixture(root)
  package_root = File.join(root, 'media_kit_video')
  native = File.join(root, 'native')
  write_plugin_fixture(plugin_dir(package_root, :ios))
  write_plugin_fixture(plugin_dir(package_root, :macos))
  FileUtils.mkdir_p(native)
  NATIVE_FILES.each { |name| File.write(File.join(native, name), "// #{name}\n") }
  [package_root, native]
end

Dir.mktmpdir('anime4k-media-kit-roots') do |root|
  ios_project = File.join(root, 'ios')
  macos_project = File.join(root, 'macos')
  assert(
    anime4k_flutter_plugin_root(project_dir: ios_project, platform: :ios) ==
      File.join(ios_project, '.symlinks', 'plugins', 'media_kit_video'),
    'iOS plugin root must use ios/.symlinks'
  )
  assert(
    anime4k_flutter_plugin_root(project_dir: macos_project, platform: :macos) ==
      File.join(macos_project, 'Flutter', 'ephemeral', '.symlinks', 'plugins', 'media_kit_video'),
    'macOS plugin root must use Flutter/ephemeral/.symlinks'
  )
end

Dir.mktmpdir('anime4k-media-kit-patch') do |root|
  package_root, native = build_package_fixture(root)
  ios_plugin = plugin_dir(package_root, :ios)
  macos_plugin = plugin_dir(package_root, :macos)

  assert(
    anime4k_media_kit_plugin_dir(plugin_root: package_root, platform: :ios) == ios_plugin,
    'resolver must select iOS source tree'
  )
  assert(
    anime4k_media_kit_plugin_dir(plugin_root: package_root, platform: :macos) == macos_plugin,
    'resolver must select macOS source tree'
  )

  texture = File.join(ios_plugin, 'TextureHW.swift')
  protocol = File.join(ios_plugin, 'common', 'ResizableTextureProtocol.swift')
  safe = File.join(ios_plugin, 'common', 'SafeResizableTexture.swift')
  video = File.join(ios_plugin, 'common', 'VideoOutput.swift')

  patch_anime4k_media_kit_video(
    plugin_root: package_root,
    native_dir: native,
    platform: :ios
  )

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

  copied = NATIVE_FILES.map { |name| File.join(ios_plugin, 'anime4k', name) }
  copied.each { |path| assert(File.file?(path), "native support missing: #{path}") }

  first = [texture, protocol, safe, video].to_h { |path| [path, File.read(path)] }
  patch_anime4k_media_kit_video(
    plugin_root: package_root,
    native_dir: native,
    platform: :ios
  )
  first.each { |path, contents| assert(File.read(path) == contents, "patch must be idempotent: #{path}") }

  patch_anime4k_media_kit_video(
    plugin_root: package_root,
    native_dir: native,
    platform: :macos
  )
  assert(
    File.read(File.join(macos_plugin, 'TextureHW.swift')).include?(marker),
    'macOS platform tree must be patched independently'
  )
end

Dir.mktmpdir('anime4k-media-kit-packaging-layout') do |root|
  package_root, native = build_package_fixture(root)
  canonical = plugin_dir(package_root, :ios)
  shifted = File.join(package_root, 'ios', 'published', 'native', 'plugin')
  FileUtils.mkdir_p(File.dirname(shifted))
  FileUtils.mv(canonical, shifted)

  resolved = anime4k_media_kit_plugin_dir(
    plugin_root: package_root,
    platform: :ios
  )
  assert(resolved == shifted, 'resolver must tolerate one unambiguous pub archive layout shift')
  patch_anime4k_media_kit_video(
    plugin_root: package_root,
    native_dir: native,
    platform: :ios
  )
  assert(
    File.read(File.join(shifted, 'TextureHW.swift')).include?('AnimeWitcherAnime4KMetalRenderHook'),
    'shifted published source tree must still be patched'
  )
end

Dir.mktmpdir('anime4k-media-kit-drift') do |root|
  package_root, native = build_package_fixture(root)
  texture = File.join(plugin_dir(package_root, :ios), 'TextureHW.swift')
  File.write(texture, TEXTURE_FIXTURE.sub("glFlush()\n\n", "glFlush()\n    // upstream changed\n"))

  begin
    patch_anime4k_media_kit_video(
      plugin_root: package_root,
      native_dir: native,
      platform: :ios
    )
    raise 'ASSERTION FAILED: source drift must fail loudly'
  rescue Anime4KMediaKitPatchError => error
    assert(error.message.include?('marker changed'), 'drift error should identify the marker')
  end
end

puts 'Anime4KMediaKitPatchTests: PASS'

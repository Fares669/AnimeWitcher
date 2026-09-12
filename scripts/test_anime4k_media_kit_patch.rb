# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'anime4k_media_kit_patch'

TEXTURE_FIXTURE = <<~'SWIFT'
  import Flutter
  import OpenGLES

  public class TextureHW: NSObject {
    private let handle: OpaquePointer
    private let updateCallback: () -> Void
    private var textureContexts = SwappableObjectManager<TextureGLESContext>(objects: [])

    public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
      return nil
    }

    public func render(_ size: CGSize) {
      let textureContext = textureContexts.nextAvailable()
      if textureContext == nil { return }
      mpv_render_context_render(renderContext, &params)
      glFlush()

      textureContexts.pushAsReady(textureContext!)
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
  native = File.join(root, 'native')
  FileUtils.mkdir_p(plugin)
  FileUtils.mkdir_p(native)
  File.write(File.join(plugin, 'TextureHW.swift'), TEXTURE_FIXTURE)
  NATIVE_FILES.each { |name| File.write(File.join(native, name), "// #{name}\n") }
  [plugin, native]
end

Dir.mktmpdir('anime4k-media-kit-patch') do |root|
  plugin, native = build_fixture(root)
  texture = File.join(plugin, 'TextureHW.swift')

  patch_anime4k_media_kit_video(
    plugin_dir: plugin,
    native_dir: native,
    platform: :ios
  )

  patched = File.read(texture)
  marker = 'AnimeWitcherAnime4KMetalRenderHook'
  assert(patched.scan(marker).length == 1, 'render marker must be inserted once')
  assert(
    patched.index('glFlush()') < patched.index(marker),
    'Metal hook must run after OpenGL flush'
  )
  assert(
    patched.index(marker) < patched.index('textureContexts.pushAsReady'),
    'Metal hook must run before media_kit publishes the frame'
  )
  assert(
    patched.include?('Anime4KMediaKitBridge.shared.process'),
    'render hook must call the shared bridge'
  )
  assert(
    patched.include?('return'),
    'submitted asynchronous processing must return before the unprocessed push'
  )

  copied = NATIVE_FILES.map { |name| File.join(plugin, 'anime4k', name) }
  copied.each { |path| assert(File.file?(path), "native support missing: #{path}") }

  first = File.read(texture)
  patch_anime4k_media_kit_video(
    plugin_dir: plugin,
    native_dir: native,
    platform: :ios
  )
  assert(File.read(texture) == first, 'patch must be idempotent')
end

Dir.mktmpdir('anime4k-media-kit-drift') do |root|
  plugin, native = build_fixture(root)
  texture = File.join(plugin, 'TextureHW.swift')
  File.write(texture, TEXTURE_FIXTURE.sub("glFlush()\n\n", "glFlush()\n    // upstream changed\n"))

  begin
    patch_anime4k_media_kit_video(
      plugin_dir: plugin,
      native_dir: native,
      platform: :ios
    )
    raise 'ASSERTION FAILED: source drift must fail loudly'
  rescue Anime4KMediaKitPatchError => error
    assert(error.message.include?('marker changed'), 'drift error should identify the marker')
  end
end

puts 'Anime4KMediaKitPatchTests: PASS'

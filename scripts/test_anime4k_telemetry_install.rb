# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'anime4k_media_kit_patch'
require_relative 'anime4k_metal_capi_install'

Dir.mktmpdir('anime4k-telemetry-install') do |root|
  plugin_dir = File.join(root, 'ios', 'Classes', 'plugin')
  native_dir = File.join(root, 'native')
  FileUtils.mkdir_p(File.join(plugin_dir, 'common'))
  FileUtils.mkdir_p(native_dir)

  {
    'TextureHW.swift' => '// TextureHW',
    File.join('common', 'ResizableTextureProtocol.swift') => '// protocol',
    File.join('common', 'SafeResizableTexture.swift') => '// safe',
    File.join('common', 'VideoOutput.swift') => '// output',
  }.each do |relative, content|
    path = File.join(plugin_dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{content}\n")
  end

  %w[
    Anime4KMetalShader.swift
    Anime4KMetalRuntime.swift
    Anime4KMediaKitBridge.swift
    Anime4KMetalTelemetry.swift
    Anime4KMetalFXScaler.swift
    Anime4KMetalCAPI.swift
  ].each do |name|
    File.write(File.join(native_dir, name), "// #{name}\n")
  end

  anime4k_sync_support_files(plugin_dir: plugin_dir, native_dir: native_dir)
  install_anime4k_metal_capi(
    plugin_root: root,
    native_dir: native_dir,
    platform: :ios
  )

  %w[Anime4KMetalTelemetry.swift Anime4KMetalFXScaler.swift Anime4KMetalCAPI.swift].each do |name|
    installed = File.join(plugin_dir, 'anime4k', name)
    raise "#{name} was not installed into media_kit" unless File.file?(installed)
  end
end

FakeConfiguration = Struct.new(:build_settings)
FakeTarget = Struct.new(:name, :build_configurations)
configs = [
  FakeConfiguration.new({ 'OTHER_LDFLAGS' => '$(inherited)' }),
  FakeConfiguration.new({ 'OTHER_LDFLAGS' => ['$(inherited)', '-framework', 'Mpv'] }),
]
target = FakeTarget.new('media_kit_video', configs)
2.times { retain_anime4k_metal_capi_symbols(target) }
ANIME4K_METAL_CAPI_SYMBOLS.each do |symbol|
  flag = "-Wl,-u,_#{symbol}"
  configs.each do |configuration|
    flags = Array(configuration.build_settings['OTHER_LDFLAGS'])
    raise "missing C API linker retention flag: #{flag}" unless flags.count(flag) == 1
  end
end

untouched = FakeConfiguration.new({ 'OTHER_LDFLAGS' => '$(inherited)' })
retain_anime4k_metal_capi_symbols(FakeTarget.new('other_plugin', [untouched]))
raise 'retention flags leaked to another pod target' unless untouched.build_settings['OTHER_LDFLAGS'] == '$(inherited)'

puts 'Anime4KMetalTelemetryInstallTests: PASS'

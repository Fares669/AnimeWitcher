# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'anime4k_media_kit_patch'

Dir.mktmpdir('anime4k-telemetry-install') do |root|
  plugin_dir = File.join(root, 'plugin')
  native_dir = File.join(root, 'native')
  FileUtils.mkdir_p(plugin_dir)
  FileUtils.mkdir_p(native_dir)

  %w[
    Anime4KMetalShader.swift
    Anime4KMetalRuntime.swift
    Anime4KMediaKitBridge.swift
    Anime4KMetalTelemetry.swift
  ].each do |name|
    File.write(File.join(native_dir, name), "// #{name}\n")
  end

  anime4k_sync_support_files(plugin_dir: plugin_dir, native_dir: native_dir)

  installed = File.join(
    plugin_dir,
    'anime4k',
    'Anime4KMetalTelemetry.swift'
  )
  raise 'Anime4K Metal telemetry support was not installed into media_kit' unless File.file?(installed)
end

puts 'Anime4KMetalTelemetryInstallTests: PASS'

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../../ios/downloader_compatibility_version'

class DM26VersionTest < Minitest::Test
  def test_export_uses_installed_pub_version_not_pod_version
    Dir.mktmpdir('dm26-version') do |root|
      directory = File.join(root, 'ios/background_downloader/Sources/background_downloader')
      FileUtils.mkdir_p(directory)
      ['9.6.1', '9.6.2', '9.6.4', '9.6.5'].each do |version|
        File.write(File.join(root, 'pubspec.yaml'), "name: background_downloader\nversion: #{version}\n")
        File.write(File.join(root, 'ios/background_downloader.podspec'), "s.version = '0.0.1'\n")
        write_downloader_compatibility_version(root)
        assert_includes File.read(File.join(directory, 'AnimeWitcherCompatibility.swift')), "= \"#{version}\""
      end
      File.write(File.join(root, 'pubspec.yaml'), "version: 'invalid'\n")
      assert_raises(RuntimeError) { write_downloader_compatibility_version(root) }
    end
  end
end

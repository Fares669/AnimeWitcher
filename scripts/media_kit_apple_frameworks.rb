require 'tempfile'

# Use the latest media-kit Darwin bundle with the existing mpv 0.36.0 ABI.
def pin_media_kit_apple_frameworks(plugin_root, platform)
  upstream_checksum, updated_checksum = {
    'ios' => %w[
      a95bc18508af26136b8a408341c05b5585d644ec013f00ac07db09d2e28d36ae
      28b528c872ca0886f1a29e8c82eb25a89c0ba86c094f2bd013b4416ad3fceba8
    ],
    'macos' => %w[
      84d2ad98e046e82c6dc34d8547d76c2afeaee89c0f53032773be8985c95536d6
      2e58ac66b0ea875239bf4db29b3ef2100a719df1d61fa1e780c38d651d4c9f27
    ]
  }.fetch(platform)
  path = File.join(plugin_root, platform, 'Makefile')
  source = File.binread(path)
  version = /^MPV_XCFRAMEWORKS_VERSION=(v[\d.]+)\r?$/
  checksum = /^MPV_XCFRAMEWORKS_SHA256SUM=([a-f0-9]{64})\r?$/
  current = [source[version, 1], source[checksum, 1]]
  return if current == ['v0.7.3', updated_checksum]
  unless current == ['v0.6.0', upstream_checksum]
    raise "Unexpected #{platform} media-kit framework pin in #{path}"
  end

  updated = source.sub('MPV_XCFRAMEWORKS_VERSION=v0.6.0', 'MPV_XCFRAMEWORKS_VERSION=v0.7.3')
                  .sub(upstream_checksum, updated_checksum)
  Tempfile.create('media-kit-makefile', File.dirname(path)) do |file|
    file.binmode
    file.write(updated)
    file.chmod(File.stat(path).mode & 0o777)
    file.close
    File.rename(file.path, path)
  end
end

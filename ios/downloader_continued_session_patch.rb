# Use the existing package delegate and controls for lease-bound manga requests.
# Validate every seam before writing; never silently patch a changed upstream.
def patch_background_downloader_continued_session(plugin_root)
  version = File.read(File.join(plugin_root, 'pubspec.yaml'))[/^version:\s*(\S+)/, 1]
  raise 'Continued download session patch requires background_downloader 9.6.5' unless version == '9.6.5'

  directory = File.join(plugin_root, 'ios/background_downloader/Sources/background_downloader')
  files = %w[BDPlugin.swift UrlSessionDelegate.swift WiFi.swift HoldingQueue.swift]
  sources = files.to_h { |name| [name, File.read(File.join(directory, name))] }
  replace = lambda do |name, before, after, count|
    source = sources.fetch(name)
    next if source.scan(after).length == count
    unless source.scan(before).length == count
      raise "background_downloader #{name} continued session seam changed"
    end
    sources[name] = source.gsub(before, after)
  end

  replace.call('BDPlugin.swift',
    'let urlSessionDownloadTask = resumeData == nil ? UrlSessionDelegate.urlSession!.downloadTask(with: request) : UrlSessionDelegate.urlSession!.downloadTask(withResumeData: resumeData!)',
    'let urlSessionDownloadTask = resumeData == nil ? AnimeWitcherDownloadSessions.session(forTaskId: task.taskId).downloadTask(with: request) : AnimeWitcherDownloadSessions.session(forTaskId: task.taskId).downloadTask(withResumeData: resumeData!)', 1)

  # URLSessionTask.taskIdentifier is unique only WITHIN its session. A page
  # completion must not remove a multipart upload's unrelated temporary file.
  replace.call('UrlSessionDelegate.swift',
    'BDPlugin.uploaderForUrlSessionTaskIdentifier.removeValue(forKey: task.taskIdentifier)',
    'task is URLSessionUploadTask ? BDPlugin.uploaderForUrlSessionTaskIdentifier.removeValue(forKey: task.taskIdentifier) : nil', 1)

  { 'BDPlugin.swift' => 1, 'UrlSessionDelegate.swift' => 3,
    'WiFi.swift' => 1, 'HoldingQueue.swift' => 1 }.each do |name, count|
    replace.call(name, 'UrlSessionDelegate.urlSession?.allTasks',
                 'AnimeWitcherDownloadSessions.allTasks()', count)
  end

  sources.each { |name, source| File.write(File.join(directory, name), source) }
  File.write(File.join(directory, 'AnimeWitcherDownloadSessions.swift'),
             File.read(File.join(__dir__, 'downloader_continued_session.swift')))
end

from pathlib import Path

path = Path('lib/features/player/presentation/player_controller.dart')
source = path.read_text()

old_signature = """  Future<Anime4kProcessingDimensions?> _resolveAnime4kMetalDimensions(
    NativePlayer platform,
  ) async {
"""
new_signature = """  Future<({
    Anime4kProcessingDimensions source,
    Anime4kProcessingDimensions output,
  })?> _resolveAnime4kMetalDimensions(NativePlayer platform) async {
"""
if old_signature not in source:
    raise SystemExit('dimension helper signature marker changed')
source = source.replace(old_signature, new_signature, 1)

old_return = """    final resolved = resolveAnime4kProcessingDimensions(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      drawableWidth: drawableWidth ?? sourceWidth,
      drawableHeight: drawableHeight ?? sourceHeight,
      previous: _anime4kProcessingDimensions,
    );
    _anime4kProcessingDimensions = resolved;
    return resolved;
"""
new_return = """    final sourceDimensions = Anime4kProcessingDimensions(
      width: sourceWidth,
      height: sourceHeight,
    );
    final resolved = resolveAnime4kProcessingDimensions(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      drawableWidth: drawableWidth ?? sourceWidth,
      drawableHeight: drawableHeight ?? sourceHeight,
      previous: _anime4kProcessingDimensions,
    );
    _anime4kProcessingDimensions = resolved;
    return (source: sourceDimensions, output: resolved);
"""
if old_return not in source:
    raise SystemExit('dimension helper return marker changed')
source = source.replace(old_return, new_return, 1)

old_config = """              source: Anime4kProcessingDimensions(
                width: dimensions.width,
                height: dimensions.height,
              ),
              output: dimensions,
"""
new_config = """              source: dimensions.source,
              output: dimensions.output,
"""
if old_config not in source:
    raise SystemExit('Metal configure dimension marker changed')
source = source.replace(old_config, new_config, 1)

old_fallback = """      // Metal is optional. A failed/unavailable setup must relinquish the
      // player before the exact same resolved pipeline is handed to mpv.
      if (metalBridge != null && metalHandle != null) {
        metalBridge.disable(handle: metalHandle);
      }
      _anime4kMetalHandle = null;
      if (!anime4kEnabled || pipeline.isEmpty) {
        _anime4kProcessingDimensions = null;
      }
"""
new_fallback = """      // Metal is optional. A failed/unavailable setup must relinquish the
      // player before the exact same resolved pipeline is handed to mpv. This
      // also disables a runtime that was already active when the user turns
      // Anime4K off; simply forgetting its Dart handle would leave native work
      // running for every frame.
      final previouslyActiveMetalHandle = _anime4kMetalHandle;
      if (previouslyActiveMetalHandle != null) {
        _disableAnime4kMetal();
      }
      if (metalBridge != null &&
          metalHandle != null &&
          metalHandle != previouslyActiveMetalHandle) {
        metalBridge.disable(handle: metalHandle);
      }
      _anime4kMetalHandle = null;
      _anime4kProcessingDimensions = null;
"""
if old_fallback not in source:
    raise SystemExit('Metal fallback marker changed')
source = source.replace(old_fallback, new_fallback, 1)

old_debug = """            'at ${_anime4kProcessingDimensions?.width}x'
            '${_anime4kProcessingDimensions?.height}',
"""
# Debug text already reads the stable output allocation, so no change required.
if old_debug not in source:
    raise SystemExit('Metal debug marker changed')

path.write_text(source)
print('Anime4K stale-runtime and source-dimension fix applied')

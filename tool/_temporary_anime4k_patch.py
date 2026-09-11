from pathlib import Path

controller = Path('lib/features/player/presentation/player_controller.dart')
source = controller.read_text()

old = '''      if (_isDisposed) return;
      if (!pipeline.isEmpty) {
        final currentVo = (await platform.getProperty('current-vo')).trim();
        final gpuDumbMode = (await platform.getProperty('gpu-dumb-mode'))
            .trim()
            .toLowerCase();
        if (!anime4kGpuRendererSupportsShaders(currentVo) ||
            gpuDumbMode == 'yes') {
          await platform.setProperty('glsl-shaders', '');
          _anime4kApplied = '';
          if (kDebugMode) {
            debugPrint(
              'Anime4K: GPU shader stage unavailable '
              '(vo="$currentVo", gpu-dumb-mode="$gpuDumbMode")',
            );
          }
          return;
        }
      }
      // An empty string is how mpv is told to run no shaders, so this both
      // applies a mode and turns one off.
      await platform.setProperty('glsl-shaders', pipeline.value);

      // Read it back. mpv accepts a malformed list without complaint and
      // simply renders nothing different, so "did it take" is a question
      // only the property itself can answer — and the answer is what tells
      // a viewer whether their folder is wrong or their eyes are.
      final applied = await platform.getProperty('glsl-shaders');
      _anime4kApplied = applied.trim();
'''

new = '''      if (_isDisposed) return;
      String currentVo = '';
      if (!pipeline.isEmpty) {
        currentVo = (await platform.getProperty('current-vo')).trim();
        if (!anime4kGpuRendererSupportsShaders(currentVo)) {
          await platform.setProperty('glsl-shaders', '');
          _anime4kApplied = '';
          if (kDebugMode) {
            debugPrint(
              'Anime4K: GPU shader stage unavailable (vo="$currentVo")',
            );
          }
          return;
        }
      }
      // An empty string is how mpv is told to run no shaders, so this both
      // applies a mode and turns one off.
      await platform.setProperty('glsl-shaders', pipeline.value);

      // Read it back. mpv accepts a malformed list without complaint and
      // simply renders nothing different, so "did it take" is a question
      // only the property itself can answer — and the answer is what tells
      // a viewer whether their folder is wrong or their eyes are.
      final applied = await platform.getProperty('glsl-shaders');
      _anime4kApplied = applied.trim();
      if (pipeline.value.isNotEmpty && _anime4kApplied.isEmpty) {
        if (kDebugMode) {
          debugPrint('Anime4K: mpv did not accept the shader chain');
        }
        return;
      }

      // gpu-dumb-mode=auto can legitimately be yes before any custom shader
      // needs an FBO. Ask mpv to load Anime4K first, then verify that it left
      // dumb mode; otherwise an idle renderer can make us reject valid shaders.
      if (!pipeline.isEmpty) {
        final gpuDumbMode = (await platform.getProperty('gpu-dumb-mode'))
            .trim()
            .toLowerCase();
        if (gpuDumbMode == 'yes') {
          await platform.setProperty('glsl-shaders', '');
          _anime4kApplied = '';
          if (kDebugMode) {
            debugPrint(
              'Anime4K: GPU shader stage unavailable '
              '(vo="$currentVo", gpu-dumb-mode="$gpuDumbMode")',
            );
          }
          return;
        }
      }
'''

count = source.count(old)
if count != 1:
    raise SystemExit(f'expected exactly one Anime4K block, found {count}')

controller.write_text(source.replace(old, new, 1))
Path('.github/workflows/_temporary_anime4k_patch.yml').unlink()
Path('tool/_temporary_anime4k_patch.py').unlink()

from __future__ import annotations

import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def apply_red() -> None:
    path = Path("scripts/test_anime4k_media_kit_patch.rb")
    text = path.read_text()

    field_needle = "    private var textureId: Int64 = -1\n"
    text = replace_once(
        text,
        field_needle,
        field_needle + "    private var disposed: Bool = false\n",
        "fixture disposed field",
    )

    assertion_needle = (
        "  assert(!video_source.include?(\"texture.render(size)\\n"
        "      DispatchQueue.main.sync\"), "
        "'old immediate publication path must be removed')\n"
    )
    assertions = assertion_needle + """  assert(
    video_source.include?('private var anime4kRenderInFlight: Bool = false'),
    'async Anime4K render must gate one publication at a time'
  )
  assert(
    video_source.include?('private var anime4kRenderPending: Bool = false'),
    'updates arriving during Metal work must collapse into one pending render'
  )
  assert(
    video_source.include?('if anime4kRenderInFlight {'),
    'VideoOutput must not start another async Anime4K render while one is in flight'
  )
  assert(
    video_source.include?('anime4kRenderPending = true'),
    'overlapping update callbacks must mark a latest-frame render pending'
  )
"""
    text = replace_once(
        text,
        assertion_needle,
        assertions,
        "mailbox RED assertions",
    )
    path.write_text(text)


def apply_green() -> None:
    path = Path("scripts/anime4k_media_kit_patch.rb")
    text = path.read_text()

    validation_needle = """  unless sources[:video].scan(video_needle).length == 1
    raise Anime4KMediaKitPatchError,
          'media_kit VideoOutput publication marker changed'
  end
"""
    validation = validation_needle + """
  video_state_needle = "  private var disposed: Bool = false\\n"
  unless sources[:video].scan(video_state_needle).length == 1
    raise Anime4KMediaKitPatchError,
          'media_kit VideoOutput state marker changed'
  end
"""
    text = replace_once(
        text,
        validation_needle,
        validation,
        "VideoOutput state validation",
    )

    start_marker = "  video_source = sources[:video].sub(\n    video_needle,"
    start = text.find(start_marker)
    end_marker = (
        "\n\n  anime4k_sync_support_files("
        "plugin_dir: plugin_dir, native_dir: native_dir)"
    )
    end = text.find(end_marker, start)
    if start < 0 or end < 0:
        raise SystemExit("VideoOutput replacement block changed")

    replacement = r'''  video_source = sources[:video].sub(
    video_state_needle,
    <<~'SWIFT'.lines.map { |line| "  #{line}" }.join
      private var disposed: Bool = false
      private var anime4kRenderInFlight: Bool = false
      private var anime4kRenderPending: Bool = false
    SWIFT
  )
  video_source = video_source.sub(
    video_needle,
    <<~'SWIFT'.lines.map { |line| "    #{line}" }.join
      // AnimeWitcherAnime4KCompletionPublication
      if Anime4KMediaKitBridge.shared.runtimeStatus(handle: handle) == .ready {
        if anime4kRenderInFlight {
          anime4kRenderPending = true
          return
        }

        anime4kRenderInFlight = true
        texture.render(size) { [weak self] in
          guard let that = self else { return }

          DispatchQueue.main.async {
            that.registry.textureFrameAvailable(that.textureId)
          }

          that.worker.enqueue { [weak self] in
            guard let that = self else { return }
            that.anime4kRenderInFlight = false
            if that.anime4kRenderPending {
              that.anime4kRenderPending = false
              that._updateCallback()
            }
          }
        }
        return
      }

      texture.render(size)
      DispatchQueue.main.sync { [weak self] in
        guard let that = self else { return }
        // Textures must be marked as available from the main thread
        that.registry.textureFrameAvailable(that.textureId)
      }
    SWIFT
  )'''
    text = text[:start] + replacement + text[end:]
    path.write_text(text)


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in {"red", "green"}:
        raise SystemExit("usage: apply_anime4k_mailbox_fix.py red|green")
    if sys.argv[1] == "red":
        apply_red()
    else:
        apply_green()


if __name__ == "__main__":
    main()

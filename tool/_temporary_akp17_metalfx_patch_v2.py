from pathlib import Path

helper = Path('tool/_temporary_akp17_metalfx_patch.py')
source = helper.read_text()

# The Actions token has contents:write but GitHub deliberately rejects workflow
# changes without the separate workflows permission. Leave workflow edits for
# the connected GitHub client, which created the temporary workflow in the
# first place, and let this runner commit production/source changes only.
start_marker = '# Native CI compiles the same support file list explicitly.'
end_marker = "adapter = Path('native/anime4k_metal/Anime4KMetalFXScaler.swift')"
start = source.index(start_marker)
end = source.index(end_marker, start)
source = source[:start] + source[end:]
source = source.replace(
    "Path('.github/workflows/_temporary_akp17_metalfx_patch.yml').unlink()\n",
    '',
)
# The original helper removes itself; this wrapper removes itself after the
# exact patch has completed, leaving no tool scaffolding in the production commit.
exec(compile(source, str(helper), 'exec'))
Path('tool/_temporary_akp17_metalfx_patch_v2.py').unlink()

from pathlib import Path
import runpy

runpy.run_path('.github/scripts/dm31_patch.py', run_name='__main__')

# Legacy tests/callers intentionally omit generation. They deserialize/construct
# as generation zero until DownloadService takes ownership and rewrites them.
path = Path('lib/core/services/download_url_refresh.dart')
source = path.read_text()
source = source.replace('    required this.generation,\n', '    this.generation = 0,\n', 1)
path.write_text(source)

from pathlib import Path
import runpy

runpy.run_path('.github/scripts/dm31_patch.py', run_name='__main__')

# Legacy tests/callers intentionally omit generation. They deserialize/construct
# as generation zero until DownloadService takes ownership and rewrites them.
path = Path('lib/core/services/download_url_refresh.dart')
source = path.read_text()
source = source.replace('    required this.generation,\n', '    this.generation = 0,\n', 1)
path.write_text(source)

# The base patch originally declared refreshDescriptorGeneration inside the
# inner persistence try, while rollback runs from the surrounding catch. Keep
# the generation fence alive for the complete start transaction so rollback can
# remove only the descriptor generation this attempt actually committed.
path = Path('lib/core/services/download_service.dart')
source = path.read_text()
inner_declaration = '        int? refreshDescriptorGeneration;\n'
outer_anchor = '''      if (kDebugMode) debugPrint('[DownloadService] Enqueuing task...');\n\n      // Create the directory if it doesn't exist\n'''
outer_replacement = '''      int? refreshDescriptorGeneration;\n\n      if (kDebugMode) debugPrint('[DownloadService] Enqueuing task...');\n\n      // Create the directory if it doesn't exist\n'''
if source.count(inner_declaration) != 1:
    raise SystemExit('DM-31 refresh descriptor generation declaration drift')
if outer_anchor not in source:
    raise SystemExit('DM-31 outer generation scope anchor drift')
source = source.replace(inner_declaration, '', 1)
source = source.replace(outer_anchor, outer_replacement, 1)
path.write_text(source)

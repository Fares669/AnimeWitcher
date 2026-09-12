from pathlib import Path
import runpy

store = Path('lib/core/services/download_url_refresh.dart').read_text()
service = Path('lib/core/services/download_service.dart').read_text()
launcher = Path('lib/features/details/presentation/download_launcher.dart').read_text()

owner_patch_present = all(
    marker in store
    for marker in (
        'final String? ownerTaskId;',
        'final String? logicalId;',
        'Future<bool> claimOwnership(',
        'Future<bool> removeForOwnerGeneration(',
    )
) and all(
    marker in service
    for marker in (
        'required String ownerTaskId,',
        'claimOwnership: true,',
        'String? refreshDescriptorOwnerTaskId;',
        '.removeForOwnerGeneration(',
    )
) and 'refreshDescriptor: DownloadUrlRefreshDescriptor(' in launcher

launcher_owns_store = (
    'await refreshStore.save(' in launcher
    or 'await refreshStore.remove(resolveUrl)' in launcher
)

if owner_patch_present and not launcher_owns_store:
    print('DM-31 owner-token production patch already present; skipping legacy migration.')
else:
    runpy.run_path('.github/scripts/dm31_patch_v2.py', run_name='__main__')

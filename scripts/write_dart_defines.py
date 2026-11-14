#!/usr/bin/env python3
"""Write build defines from the Actions environment, without logging values."""
import json
import os
from pathlib import Path

KEYS = (
    'MAL_CLIENT_ID', 'MAL_CLIENT_SECRET', 'ANILIST_CLIENT_ID',
    'ANIMEWITCHER_FIREBASE_PROJECT_ID', 'ANIMEWITCHER_FIREBASE_API_KEY',
    'ANIMERIFT_FIREBASE_API_KEY', 'ANIMERIFT_FIREBASE_APP_ID', 'ANIMERIFT_JWT_SECRET',
)

def write_defines(path: Path) -> None:
    values = {key: os.environ.get(key, '') for key in KEYS}
    missing = [key for key in KEYS if key.startswith('ANIMERIFT_') and not values[key]]
    if missing:
        raise SystemExit('Missing build secrets: ' + ', '.join(missing))
    with open(path, 'w', encoding='utf-8', opener=lambda p, flags: os.open(p, flags, 0o600)) as output:
        json.dump(values, output, ensure_ascii=False)
        output.write('\n')

if __name__ == '__main__':
    write_defines(Path('dart-defines.json'))

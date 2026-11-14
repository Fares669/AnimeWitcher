import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('defines', ROOT / 'scripts/write_dart_defines.py')
defines = importlib.util.module_from_spec(spec)
spec.loader.exec_module(defines)

class BuildDefinesTest(unittest.TestCase):
    def test_round_trip_quotes_and_newlines_without_unrelated_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'defines.json'
            fixture = {key: 'fixture' for key in defines.KEYS}
            fixture['ANIMERIFT_JWT_SECRET'] = 'quote"\nnewline\\literal'
            with patch.dict(os.environ, {**fixture, 'UNRELATED_SECRET': 'must-not-include'}, clear=True):
                defines.write_defines(target)
            self.assertEqual(json.loads(target.read_text()), fixture)
            if os.name != 'nt':
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_missing_configuration_fails_before_creating_artifact(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            target = Path(directory) / 'defines.json'
            with self.assertRaises(SystemExit):
                defines.write_defines(target)
            self.assertFalse(target.exists())

if __name__ == '__main__':
    unittest.main()

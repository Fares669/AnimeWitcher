#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts" / "mpv_runtime" / "verify_windows_runtime.py"
ARCHES = ("x64", "arm64")


def _write_dll(path: Path, marker: bytes) -> None:
    path.write_bytes(b"MZ" + b"\x00" * 62 + marker + b"\x00")


def _run_verifier(dlls: dict[str, Path]):
    command = [sys.executable, str(VERIFIER)]
    for arch in ARCHES:
        path = dlls.get(arch)
        if path is not None:
            command.extend(["--dll", f"{arch}={path}"])
    return subprocess.run(command, cwd=ROOT, capture_output=True, text=True)


class WindowsRuntimeVerifierTest(unittest.TestCase):
    def test_accepts_exact_target_version_for_both_architectures(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dlls = {}
            for arch in ARCHES:
                path = root / arch / "libmpv-2.dll"
                path.parent.mkdir(parents=True)
                _write_dll(path, b"mpv 0.41.0")
                dlls[arch] = path

            result = _run_verifier(dlls)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("windows mpv runtime: v0.41.0", result.stdout)

    def test_rejects_old_runtime(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dlls = {}
            for arch in ARCHES:
                path = root / arch / "libmpv-2.dll"
                path.parent.mkdir(parents=True)
                _write_dll(path, b"mpv 0.39.0" if arch == "x64" else b"mpv 0.41.0")
                dlls[arch] = path

            result = _run_verifier(dlls)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("x64", result.stderr)
            self.assertIn("v0.41.0", result.stderr)

    def test_rejects_missing_architecture(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "x64" / "libmpv-2.dll"
            path.parent.mkdir(parents=True)
            _write_dll(path, b"mpv 0.41.0")

            result = _run_verifier({"x64": path})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("arm64", result.stderr)

    def test_rejects_non_pe_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dlls = {}
            for arch in ARCHES:
                path = root / arch / "libmpv-2.dll"
                path.parent.mkdir(parents=True)
                if arch == "x64":
                    path.write_bytes(b"not-a-pe mpv 0.41.0")
                else:
                    _write_dll(path, b"mpv 0.41.0")
                dlls[arch] = path

            result = _run_verifier(dlls)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("PE", result.stderr)


if __name__ == "__main__":
    unittest.main()

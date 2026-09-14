#!/usr/bin/env python3
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts" / "mpv_runtime" / "verify_android_runtime.py"
ABIS = ("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
REQUIRED_HELPER_SYMBOL = b"mpv_lavc_set_java_vm"


def _write_jar(
    path: Path,
    abi: str,
    marker: bytes,
    *,
    include_helper_symbol: bool = True,
) -> None:
    payload = b"\x7fELF\x00" + marker + b"\x00"
    if include_helper_symbol:
        payload += REQUIRED_HELPER_SYMBOL + b"\x00"
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"jni/{abi}/libmpv.so", payload)


def _run_verifier(jars: dict[str, Path]):
    command = [sys.executable, str(VERIFIER)]
    for abi in ABIS:
        path = jars.get(abi)
        if path is not None:
            command.extend(["--jar", f"{abi}={path}"])
    return subprocess.run(command, cwd=ROOT, capture_output=True, text=True)



def _write_apk(path: Path, markers: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for abi in ABIS:
            payload = b"\x7fELF\x00" + markers[abi] + b"\x00"
            payload += REQUIRED_HELPER_SYMBOL + b"\x00"
            archive.writestr(f"lib/{abi}/libmpv.so", payload)


def _run_apk_verifier(path: Path):
    command = [sys.executable, str(VERIFIER), "--apk", str(path)]
    return subprocess.run(command, cwd=ROOT, capture_output=True, text=True)


class AndroidRuntimeVerifierTest(unittest.TestCase):
    def test_accepts_exact_target_version_in_built_apk(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk = Path(tmp) / "app-release.apk"
            _write_apk(apk, {abi: b"mpv 0.41.0" for abi in ABIS})

            result = _run_apk_verifier(apk)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("artifact: APK", result.stdout)

    def test_rejects_old_mpv_in_built_apk(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk = Path(tmp) / "app-release.apk"
            _write_apk(
                apk,
                {
                    abi: (b"mpv 0.36.0" if abi == "x86_64" else b"mpv 0.41.0")
                    for abi in ABIS
                },
            )

            result = _run_apk_verifier(apk)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("x86_64", result.stderr)
            self.assertIn("v0.41.0", result.stderr)

    def test_accepts_exact_target_version_for_all_abis(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            jars = {}
            for abi in ABIS:
                path = root / f"default-{abi}.jar"
                _write_jar(path, abi, b"mpv 0.41.0")
                jars[abi] = path

            result = _run_verifier(jars)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("android mpv runtime: v0.41.0", result.stdout)
            self.assertIn("mpv_lavc_set_java_vm", result.stdout)

    def test_rejects_old_mpv_even_when_all_abis_are_present(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            jars = {}
            for abi in ABIS:
                path = root / f"default-{abi}.jar"
                marker = b"mpv 0.36.0" if abi == "arm64-v8a" else b"mpv 0.41.0"
                _write_jar(path, abi, marker)
                jars[abi] = path

            result = _run_verifier(jars)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("arm64-v8a", result.stderr)
            self.assertIn("v0.41.0", result.stderr)

    def test_rejects_missing_architecture(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            jars = {}
            for abi in ABIS[:-1]:
                path = root / f"default-{abi}.jar"
                _write_jar(path, abi, b"mpv 0.41.0")
                jars[abi] = path

            result = _run_verifier(jars)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("x86_64", result.stderr)

    def test_rejects_jar_whose_native_entry_targets_another_abi(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            jars = {}
            for abi in ABIS:
                path = root / f"default-{abi}.jar"
                embedded_abi = "x86" if abi == "arm64-v8a" else abi
                _write_jar(path, embedded_abi, b"mpv 0.41.0")
                jars[abi] = path

            result = _run_verifier(jars)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("arm64-v8a", result.stderr)
            self.assertIn("libmpv.so", result.stderr)

    def test_rejects_runtime_without_media_kit_java_vm_bridge(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            jars = {}
            for abi in ABIS:
                path = root / f"default-{abi}.jar"
                _write_jar(
                    path,
                    abi,
                    b"mpv 0.41.0",
                    include_helper_symbol=abi != "x86_64",
                )
                jars[abi] = path

            result = _run_verifier(jars)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("x86_64", result.stderr)
            self.assertIn("mpv_lavc_set_java_vm", result.stderr)


if __name__ == "__main__":
    unittest.main()

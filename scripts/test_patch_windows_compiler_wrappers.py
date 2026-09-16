#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "mpv_runtime" / "patch_windows_compiler_wrappers.py"


def _load_helper():
    spec = importlib.util.spec_from_file_location("patch_windows_compiler_wrappers", HELPER)
    if spec is None or spec.loader is None:
        raise AssertionError(f"unable to load helper: {HELPER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WindowsCompilerWrapperPatchTests(unittest.TestCase):
    def test_adds_libcxx_flags_and_is_idempotent(self):
        self.assertTrue(HELPER.is_file(), f"missing wrapper patch helper: {HELPER}")
        helper = _load_helper()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bin_dir = root / "bin"
            sysroot = root / "build_x86_64" / "x86_64-w64-mingw32"
            resource_dir = root / "clang_root" / "lib" / "clang" / "20"
            (sysroot / "include" / "c++" / "v1").mkdir(parents=True)
            resource_dir.mkdir(parents=True)
            bin_dir.mkdir()
            toolchain = sysroot.parent / "toolchain.cmake"
            toolchain.write_text("set(CMAKE_SYSTEM_NAME Windows)\n", encoding="utf-8")

            cmake = root / "cmake"
            cmake.mkdir()
            cleanup_generator = cmake / "custom_steps.cmake"
            cleanup_generator.write_text(
                "function(force_rebuild_git _name)\n"
                "    get_property(git_tag TARGET ${_name} PROPERTY _EP_GIT_TAG)\n"
                "    get_property(git_reset TARGET ${_name} PROPERTY _EP_GIT_RESET)\n"
                "    get_property(git_remote_name TARGET ${_name} PROPERTY _EP_GIT_REMOTE_NAME)\n"
                "    get_property(stamp_dir TARGET ${_name} PROPERTY _EP_STAMP_DIR)\n"
                "    get_property(source_dir TARGET ${_name} PROPERTY _EP_SOURCE_DIR)\n"
                "\n"
                '    if("${git_remote_name}" STREQUAL "" AND NOT "${git_tag}" STREQUAL "")\n'
                "        # GIT_REMOTE_NAME is not set when commit hash is specified\n"
                '        set(reset "")\n'
                '    elseif(NOT "${git_reset}" STREQUAL "")\n'
                '        set(reset "${git_reset}")\n'
                "    else()\n"
                '        set(reset "@{u}") # eg: origin/master\n'
                "    endif()\n"
                "\n"
                "file(WRITE ${stamp_dir}/reset_head.sh\n"
                '"#!/bin/bash\\n'
                "set -e\\n"
                'if [[ ! -f \\"${stamp_dir}/${_name}-patch\\"  || \\"${stamp_dir}/${_name}-download\\" -nt \\"${stamp_dir}/${_name}-patch\\" || ! -f \\"${stamp_dir}/HEAD\\" || \\"$(cat ${stamp_dir}/HEAD)\\" != \\"$(git -C ${source_dir} rev-parse @{u})\\" ]]; then\\n'
                "    echo ${source_dir}\\n"
                '    git -C ${source_dir} reset --hard ${reset} -q\\n'
                'fi")\n'
                "endfunction()\n",
                encoding="utf-8",
            )

            packages = root / "packages"
            packages.mkdir()
            openal_package = packages / "openal-soft.cmake"
            openal_package.write_text(
                "ExternalProject_Add(openal-soft\n"
                "    CONFIGURE_COMMAND cmake -H<SOURCE_DIR> -B<BINARY_DIR>\n"
                "        -DALSOFT_TESTS=OFF\n"
                "        -DALSOFT_BACKEND_PIPEWIRE=OFF\n"
                ")\n",
                encoding="utf-8",
            )
            for compiler in ("clang++", "g++", "c++"):
                (bin_dir / f"x86_64-w64-mingw32-{compiler}").write_text(
                    "#!/bin/bash\n"
                    "PROG=/clang_root/bin/clang++\n"
                    'FLAGS="$FLAGS --sysroot /old/sysroot"\n'
                    'if [ "clang++" = "clang++" ]; then\n'
                    '    FLAGS="$FLAGS -stdlib=libc++"\n'
                    '    FLAGS="$FLAGS -isystem /old/sysroot/include/c++/v1"\n'
                    '    FLAGS="$FLAGS -resource-dir /old/clang"\n'
                    '    FLAGS="$FLAGS --rtlib=compiler-rt --unwindlib=libunwind"\n'
                    "fi\n"
                    '$CCACHE "$PROG" "$@" $FLAGS\n',
                    encoding="utf-8",
                )

            changed = helper.patch_wrappers(
                bin_dir=bin_dir,
                sysroot=sysroot,
                resource_dir=resource_dir,
                target_prefix="x86_64-w64-mingw32",
            )
            self.assertEqual(
                changed,
                [
                    "x86_64-w64-mingw32-clang++",
                    "x86_64-w64-mingw32-g++",
                    "x86_64-w64-mingw32-c++",
                ],
            )
            wrapper = bin_dir / "x86_64-w64-mingw32-g++"
            patched = wrapper.read_text(encoding="utf-8")
            syntax = subprocess.run(
                ["bash", "-n", str(wrapper)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(syntax.returncode, 0, syntax.stderr)
            invocation = next(
                line for line in patched.splitlines() if line.startswith('$CCACHE "$PROG"')
            )
            self.assertIn(f"-resource-dir {resource_dir}", invocation)
            self.assertIn("--rtlib=compiler-rt --unwindlib=libunwind", invocation)
            self.assertIn("-stdlib=libc++", invocation)
            self.assertIn(f'-isystem {sysroot / "include/c++/v1"}', invocation)

            toolchain_text = toolchain.read_text(encoding="utf-8")
            self.assertIn(
                'set(ALSOFT_ENABLE_MODULES OFF CACHE BOOL "Disable OpenAL C++20 modules for cross compiler wrapper compatibility" FORCE)',
                toolchain_text,
            )
            openal_text = openal_package.read_text(encoding="utf-8")
            self.assertEqual(openal_text.count("-DALSOFT_ENABLE_MODULES=OFF"), 1)
            self.assertEqual(openal_text.count("-DCMAKE_CXX_SCAN_FOR_MODULES=OFF"), 1)

            cleanup_text = cleanup_generator.read_text(encoding="utf-8")
            self.assertEqual(
                cleanup_text.count("# AnimeWitcher: detached-safe cleanup comparison"),
                1,
            )
            self.assertIn('MATCHES "^[0-9a-fA-F]{40}$"', cleanup_text)
            self.assertIn('set(reset_compare_ref "HEAD")', cleanup_text)
            self.assertIn("rev-parse ${reset_compare_ref}", cleanup_text)
            self.assertNotIn("rev-parse @{u})", cleanup_text)

            self.assertEqual(
                helper.patch_wrappers(
                    bin_dir=bin_dir,
                    sysroot=sysroot,
                    resource_dir=resource_dir,
                    target_prefix="x86_64-w64-mingw32",
                ),
                [],
            )
            self.assertEqual(wrapper.read_text(encoding="utf-8"), patched)
            self.assertEqual(
                toolchain.read_text(encoding="utf-8").count("ALSOFT_ENABLE_MODULES"),
                1,
            )
            self.assertEqual(
                openal_package.read_text(encoding="utf-8").count("CMAKE_CXX_SCAN_FOR_MODULES"),
                1,
            )
            self.assertEqual(
                cleanup_generator.read_text(encoding="utf-8").count(
                    "# AnimeWitcher: detached-safe cleanup comparison"
                ),
                1,
            )

    def test_rejects_missing_libcxx_headers(self):
        self.assertTrue(HELPER.is_file(), f"missing wrapper patch helper: {HELPER}")
        helper = _load_helper()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(RuntimeError, "libc\\+\\+ headers"):
                helper.patch_wrappers(
                    bin_dir=root / "bin",
                    sysroot=root / "sysroot",
                    resource_dir=root / "resource",
                    target_prefix="x86_64-w64-mingw32",
                )


if __name__ == "__main__":
    unittest.main()

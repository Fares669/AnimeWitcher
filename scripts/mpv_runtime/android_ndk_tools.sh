#!/usr/bin/env bash
set -euo pipefail

find_android_ndk_llvm_tool() {
  if [[ $# -ne 2 ]]; then
    echo "usage: find_android_ndk_llvm_tool <android-sdk> <tool-name>" >&2
    return 64
  fi
  local android_sdk="$1"
  local tool_name="$2"
  local tool
  tool="$(find "$android_sdk/ndk" \
    -path "*/29.*/toolchains/llvm/prebuilt/*/bin/$tool_name" \
    -print -quit 2>/dev/null || true)"
  if [[ -z "$tool" || ! -x "$tool" ]]; then
    echo "$tool_name not found in Android NDK r29 under $android_sdk/ndk" >&2
    return 1
  fi
  printf '%s\n' "$tool"
}

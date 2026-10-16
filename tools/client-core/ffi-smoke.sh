#!/usr/bin/env bash
# 经 C ABI 冒烟测试 client-core 的绑定接口（见 ffi_smoke.py）。
set -euo pipefail
cd "$(dirname "$0")/../.."
cargo build -p client-core --lib
lib="target/debug/libclient_core.so"
[[ "$(uname)" == "Darwin" ]] && lib="target/debug/libclient_core.dylib"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
cargo run -q -p client-core --features bindgen --bin uniffi-bindgen -- \
  generate "$lib" --language python --out-dir "$dir" --no-format >/dev/null
cp "$lib" "$dir/"
python3 -I tools/client-core/ffi_smoke.py "$dir"

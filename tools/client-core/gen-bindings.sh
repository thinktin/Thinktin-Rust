#!/usr/bin/env bash
# 生成 client-core 的 Swift / Kotlin 绑定（WBS 11.1）。
# 用本机编出来的动态库读接口元数据（library mode），所以不需要交叉编译工具链。
#
#   tools/client-core/gen-bindings.sh [输出目录，默认 target/bindings]
#
# 输出：
#   swift/ThinktinCore.swift、swift/ThinktinCoreFFI.h、swift/module.modulemap
#   kotlin/cn/thinktin/core/client_core.kt
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-target/bindings}"

cargo build -p client-core --lib
lib="target/debug/libclient_core.so"
[[ "$(uname)" == "Darwin" ]] && lib="target/debug/libclient_core.dylib"

rm -rf "$out/swift" "$out/kotlin"
mkdir -p "$out/swift" "$out/kotlin"
cargo run -q -p client-core --features bindgen --bin uniffi-bindgen -- \
  generate "$lib" --language swift --out-dir "$out/swift" --no-format
cargo run -q -p client-core --features bindgen --bin uniffi-bindgen -- \
  generate "$lib" --language kotlin --out-dir "$out/kotlin" --no-format
# xcframework 里的头文件目录要求模块映射文件叫 module.modulemap。
mv "$out/swift/ThinktinCoreFFI.modulemap" "$out/swift/module.modulemap"
echo "bindings written to $out"

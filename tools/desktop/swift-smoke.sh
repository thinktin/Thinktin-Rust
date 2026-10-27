#!/usr/bin/env bash
# 在 Linux 上验 `desktop` 的 UniFFI 接口（macOS App 用，14.5）：`build-linux-swift.sh --desktop` 打出 macOS App 那种
# ThinktinCore 包（libdesktop 里也有 client-core；两份绑定在同一个 Swift 模块、两个头文件在同一个 C 模块），再编、跑
# smoke/main.swift（Swift 实现令牌、系统工具、观察者，Rust 回调它们）。
#
#   tools/desktop/swift-smoke.sh [输出目录，默认 target/desktop-swift]
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-target/desktop-swift}"
[[ "$(uname)" == "Linux" ]] || { echo "needs Linux" >&2; exit 1; }

tools/client-core/build-linux-swift.sh --desktop
core="$(pwd)/target/linux-desktop/ThinktinCore"
libdir="$(pwd)/target/debug"
rm -rf "$out"
mkdir -p "$out/Sources/DesktopSmoke"
cp tools/desktop/smoke/main.swift "$out/Sources/DesktopSmoke/"
cat > "$out/Package.swift" <<SWIFT
// swift-tools-version:5.9
// 由 tools/desktop/swift-smoke.sh 生成，不要手改。
import PackageDescription

let package = Package(
    name: "DesktopSmoke",
    dependencies: [.package(name: "ThinktinCore", path: "$core")],
    targets: [
        .executableTarget(
            name: "DesktopSmoke", dependencies: [.product(name: "ThinktinCore", package: "ThinktinCore")]),
    ]
)
SWIFT
(cd "$out" && swift build && LD_LIBRARY_PATH="$libdir" .build/debug/DesktopSmoke)

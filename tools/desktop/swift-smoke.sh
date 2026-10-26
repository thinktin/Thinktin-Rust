#!/usr/bin/env bash
# 在 Linux 上验 `desktop` 的 UniFFI 接口（macOS App 用，14.5）：编 libdesktop（里面也有 client-core），按库生成
# 两份 Swift 绑定，放进同一个 Swift 模块，跑 smoke/main.swift（Swift 实现令牌、系统工具、观察者，Rust 回调它们）。
#
#   tools/desktop/swift-smoke.sh [输出目录，默认 target/desktop-swift]
#
# 打包的样子和 macOS App 要用的一样：
# - 一个 C 模块映射里放两个 FFI 模块（ThinktinCoreFFI、ThinktinDesktopFFI），都链接 libdesktop；
# - 两份生成的 Swift（ThinktinCore.swift、ThinktinDesktop.swift）编进同一个 Swift 模块 ThinktinCore：desktop 的绑定直接用
#   client-core 的类型（`CapabilityGrant`），不另外 import。iOS App 照旧只用 client-core。
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-target/desktop-swift}"
[[ "$(uname)" == "Linux" ]] || { echo "needs Linux" >&2; exit 1; }

cargo build -p desktop --lib
libdir="$(pwd)/target/debug"
bindings="$out/bindings"
rm -rf "$out"
mkdir -p "$bindings" "$out/Sources/ThinktinFFI" "$out/Sources/ThinktinCore" "$out/Sources/DesktopSmoke"
cargo run -q -p client-core --features bindgen --bin uniffi-bindgen -- \
  generate "$libdir/libdesktop.so" --language swift --out-dir "$bindings" --no-format
cp "$bindings/ThinktinCoreFFI.h" "$bindings/ThinktinDesktopFFI.h" "$out/Sources/ThinktinFFI/"
cat > "$out/Sources/ThinktinFFI/module.modulemap" <<'MAP'
module ThinktinCoreFFI {
    header "ThinktinCoreFFI.h"
    link "desktop"
    export *
}
module ThinktinDesktopFFI {
    header "ThinktinDesktopFFI.h"
    link "desktop"
    export *
}
MAP
cp "$bindings/ThinktinCore.swift" "$bindings/ThinktinDesktop.swift" "$out/Sources/ThinktinCore/"
cp tools/desktop/smoke/main.swift "$out/Sources/DesktopSmoke/"
cat > "$out/Package.swift" <<SWIFT
// swift-tools-version:5.9
// 由 tools/desktop/swift-smoke.sh 生成，不要手改。
import PackageDescription

let package = Package(
    name: "DesktopSmoke",
    targets: [
        .systemLibrary(name: "ThinktinFFI", path: "Sources/ThinktinFFI"),
        .target(
            name: "ThinktinCore",
            dependencies: ["ThinktinFFI"],
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])],
            linkerSettings: [.unsafeFlags(["-L$libdir", "-Xlinker", "-rpath", "-Xlinker", "$libdir"])]
        ),
        .executableTarget(name: "DesktopSmoke", dependencies: ["ThinktinCore"]),
    ]
)
SWIFT
(cd "$out" && swift build && LD_LIBRARY_PATH="$libdir" .build/debug/DesktopSmoke)

#!/usr/bin/env bash
# 在 Linux 上把 client-core 打成 Swift 包 `ThinktinCore`（WBS 12.1），给没有 Xcode 的环境（云端会话、CI 的
# ubuntu 任务）编译和测试 ThinktinKit 的纯 Swift 部分和 ThinktinCore 适配层。接口和 build-apple.sh 打出来的
# 包完全一样（同一份 UniFFI 绑定），只是二进制换成本机的 libclient_core.so。
#
#   tools/client-core/build-linux-swift.sh [输出目录，默认 target/linux] [--release]
#
# 输出：<out>/ThinktinCore/（Package.swift、系统库模块 ThinktinCoreFFI、ThinktinCore.swift）。
# 用的时候：swift build / swift test 照常；运行测试时 libclient_core.so 要在 LD_LIBRARY_PATH 里
# （脚本最后会打印）。
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-target/linux}"
profile=debug
[[ "${2:-}" == "--release" ]] && profile=release
[[ "$(uname)" == "Linux" ]] || { echo "needs Linux; on macOS use build-apple.sh" >&2; exit 1; }

if [[ "$profile" == "release" ]]; then
  cargo build -p client-core --lib --release
else
  cargo build -p client-core --lib
fi
libdir="$(pwd)/target/$profile"
[[ -f "$libdir/libclient_core.so" ]] || { echo "missing $libdir/libclient_core.so" >&2; exit 1; }

tools/client-core/gen-bindings.sh "$out/bindings"

pkg="$out/ThinktinCore"
rm -rf "$pkg"
mkdir -p "$pkg/Sources/ThinktinCoreFFI" "$pkg/Sources/ThinktinCore"
cp "$out/bindings/swift/ThinktinCoreFFI.h" "$pkg/Sources/ThinktinCoreFFI/"
cat > "$pkg/Sources/ThinktinCoreFFI/module.modulemap" <<'MAP'
module ThinktinCoreFFI {
    header "ThinktinCoreFFI.h"
    link "client_core"
    export *
}
MAP
cp "$out/bindings/swift/ThinktinCore.swift" "$pkg/Sources/ThinktinCore/"
# 包资源（许可证）给外面的模块用：SwiftPM 生成的 Bundle.module 是 internal 的。
cat > "$pkg/Sources/ThinktinCore/Resources.swift" <<'RES'
import Foundation

/// client-core 依赖的 crate 的许可证清单（`Licenses/NOTICES.md`、`inventory.json`、`texts/`）。
public enum ThinktinCoreResources {
    public static let bundle: Bundle = Bundle.module
}
RES
# 客户端核心依赖的 crate 的许可证清单（和 build-apple.sh 一样放进包资源，App 的“开源许可”页面读）。
python3 tools/licenses/licenses.py cargo -p client-core --subject client-core --out "$pkg/Sources/ThinktinCore/Licenses"
cat > "$pkg/Package.swift" <<SWIFT
// swift-tools-version:5.9
// 由 tools/client-core/build-linux-swift.sh 生成，不要手改。
import PackageDescription

let package = Package(
    name: "ThinktinCore",
    products: [.library(name: "ThinktinCore", targets: ["ThinktinCore"])],
    targets: [
        .systemLibrary(name: "ThinktinCoreFFI", path: "Sources/ThinktinCoreFFI"),
        .target(
            name: "ThinktinCore",
            dependencies: ["ThinktinCoreFFI"],
            resources: [.copy("Licenses")],
            linkerSettings: [.unsafeFlags(["-L$libdir", "-Xlinker", "-rpath", "-Xlinker", "$libdir"])]
        ),
    ]
)
SWIFT
echo "Swift package at $pkg"
echo "export LD_LIBRARY_PATH=$libdir"

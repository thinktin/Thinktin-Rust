#!/usr/bin/env bash
# 打 iOS / macOS 用的 xcframework 和 Swift Package（WBS 11.1）。只能在 macOS 上跑，需要 Xcode。
# aws-lc-rs（TLS）交叉编译需要 cmake。
#
#   tools/client-core/build-apple.sh [输出目录，默认 target/apple] [--ci]
#
# 输出：<out>/ThinktinCore/（Swift Package：ThinktinCoreFFI.xcframework + ThinktinCore.swift），
# App 工程里按本地包引用。
#
# --ci：只编 aarch64-apple-ios-sim 和 aarch64-apple-darwin 两个 Rust 目标，xcframework 只有模拟器和
# macOS 两个 arm64 切片（GitHub 的 macos runner 是 Apple Silicon，CI 只在模拟器上跑测试、在本机编
# ThinktinKit；见 .github/workflows/ios.yml）。少编三个目标，省一大半时间。打不出真机包，发布不要用。
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "$(uname)" == "Darwin" ]] || { echo "needs macOS with Xcode" >&2; exit 1; }
ci=0
args=()
for a in "$@"; do
  if [[ "$a" == "--ci" ]]; then ci=1; else args+=("$a"); fi
done
out="${args[0]:-target/apple}"
profile=mobile
if (( ci )); then
  targets=(aarch64-apple-ios-sim aarch64-apple-darwin)
else
  targets=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin)
fi

rustup target add "${targets[@]}"
for t in "${targets[@]}"; do
  cargo build -p client-core --lib --profile "$profile" --target "$t"
done
lib() { echo "target/$1/$profile/libclient_core.a"; }

rm -rf "$out"
mkdir -p "$out/sim" "$out/macos" "$out/headers"
sim_libs=("$(lib aarch64-apple-ios-sim)")
macos_libs=("$(lib aarch64-apple-darwin)")
if (( ! ci )); then
  sim_libs+=("$(lib x86_64-apple-ios)")
  macos_libs+=("$(lib x86_64-apple-darwin)")
fi
lipo -create "${sim_libs[@]}" -output "$out/sim/libclient_core.a"
lipo -create "${macos_libs[@]}" -output "$out/macos/libclient_core.a"

tools/client-core/gen-bindings.sh "$out/bindings"
cp "$out/bindings/swift/ThinktinCoreFFI.h" "$out/bindings/swift/module.modulemap" "$out/headers/"

pkg="$out/ThinktinCore"
mkdir -p "$pkg/Sources/ThinktinCore"
slices=()
if (( ! ci )); then
  slices+=(-library "$(lib aarch64-apple-ios)" -headers "$out/headers")
fi
slices+=(-library "$out/sim/libclient_core.a" -headers "$out/headers")
slices+=(-library "$out/macos/libclient_core.a" -headers "$out/headers")
xcodebuild -create-xcframework "${slices[@]}" -output "$pkg/ThinktinCoreFFI.xcframework"
cp "$out/bindings/swift/ThinktinCore.swift" "$pkg/Sources/ThinktinCore/"
# 和 build-linux-swift.sh 打出来的包接口一致：包资源（许可证）给外面的模块用，SwiftPM 生成的
# Bundle.module 是 internal 的。
cat > "$pkg/Sources/ThinktinCore/Resources.swift" <<'RES'
import Foundation

/// client-core 依赖的 crate 的许可证清单（`Licenses/NOTICES.md`、`inventory.json`、`texts/`）。
public enum ThinktinCoreResources {
    public static let bundle: Bundle = Bundle.module
}
RES
# 客户端核心依赖的 crate 的许可证原文和清单（WBS 16.5，docs/licenses.md），App 的“开源许可”页面
# 从 Bundle.module 的 Licenses 目录读。
python3 tools/licenses/licenses.py cargo -p client-core --subject client-core --out "$pkg/Sources/ThinktinCore/Licenses"
cat > "$pkg/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ThinktinCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ThinktinCore", targets: ["ThinktinCore"])],
    targets: [
        .binaryTarget(name: "ThinktinCoreFFI", path: "ThinktinCoreFFI.xcframework"),
        .target(
            name: "ThinktinCore",
            dependencies: ["ThinktinCoreFFI"],
            resources: [.copy("Licenses")],
            linkerSettings: [.linkedFramework("SystemConfiguration"), .linkedFramework("Security")]
        ),
    ]
)
SWIFT
echo "Swift package at $pkg"

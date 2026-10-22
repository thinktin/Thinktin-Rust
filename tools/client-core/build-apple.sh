#!/usr/bin/env bash
# 打 iOS / macOS 用的 xcframework 和 Swift Package（WBS 11.1）。只能在 macOS 上跑，需要 Xcode。
# aws-lc-rs（TLS）交叉编译需要 cmake。
#
#   tools/client-core/build-apple.sh [输出目录，默认 target/apple]
#
# 输出：<out>/ThinktinCore/（Swift Package：ThinktinCoreFFI.xcframework + ThinktinCore.swift），
# App 工程里按本地包引用。
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "$(uname)" == "Darwin" ]] || { echo "needs macOS with Xcode" >&2; exit 1; }
out="${1:-target/apple}"
profile=mobile
targets=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin)

rustup target add "${targets[@]}"
for t in "${targets[@]}"; do
  cargo build -p client-core --lib --profile "$profile" --target "$t"
done
lib() { echo "target/$1/$profile/libclient_core.a"; }

rm -rf "$out"
mkdir -p "$out/sim" "$out/macos" "$out/headers"
lipo -create "$(lib aarch64-apple-ios-sim)" "$(lib x86_64-apple-ios)" -output "$out/sim/libclient_core.a"
lipo -create "$(lib aarch64-apple-darwin)" "$(lib x86_64-apple-darwin)" -output "$out/macos/libclient_core.a"

tools/client-core/gen-bindings.sh "$out/bindings"
cp "$out/bindings/swift/ThinktinCoreFFI.h" "$out/bindings/swift/module.modulemap" "$out/headers/"

pkg="$out/ThinktinCore"
mkdir -p "$pkg/Sources/ThinktinCore"
xcodebuild -create-xcframework \
  -library "$(lib aarch64-apple-ios)" -headers "$out/headers" \
  -library "$out/sim/libclient_core.a" -headers "$out/headers" \
  -library "$out/macos/libclient_core.a" -headers "$out/headers" \
  -output "$pkg/ThinktinCoreFFI.xcframework"
cp "$out/bindings/swift/ThinktinCore.swift" "$pkg/Sources/ThinktinCore/"
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

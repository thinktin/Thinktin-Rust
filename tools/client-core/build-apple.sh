#!/usr/bin/env bash
# 打 iOS / macOS 用的 xcframework 和 Swift Package（WBS 11.1）。只能在 macOS 上跑，需要 Xcode。
# aws-lc-rs（TLS）交叉编译需要 cmake。
#
#   tools/client-core/build-apple.sh [输出目录，默认 target/apple] [--ci] [--macos]
#
# 输出：<out>/ThinktinCore/（Swift Package：ThinktinCoreFFI.xcframework + ThinktinCore.swift），
# App 工程里按本地包引用。
#
# macOS 切片是 libdesktop（电脑端的工具服务，14.5；里面也有 client-core），iOS 切片是 libclient_core。绑定按
# libdesktop 生成两份：ThinktinCore.swift 两边都用；ThinktinDesktop.swift 包在 `#if os(macOS)` 里（iOS 的库里没有
# 这些符号）。两个头文件在同一个 C 模块 ThinktinCoreFFI 里（共用的定义有防重复的宏），和 Linux 上
# `build-linux-swift.sh --desktop` 打出来的样子一样（tools/desktop/swift-smoke.sh 在 Linux 上验这个样子）。
#
# --ci：只编 aarch64-apple-ios-sim 和 aarch64-apple-darwin 两个 Rust 目标，xcframework 只有模拟器和
# macOS 两个 arm64 切片（GitHub 的 macos runner 是 Apple Silicon，CI 只在模拟器上跑测试、在本机编
# ThinktinKit；见 .github/workflows/ios.yml）。少编三个目标，省一大半时间。打不出真机包，发布不要用。
#
# --macos：只打 macOS 的切片（arm64 + x86_64 的胖库），给 macOS App 发版用（14.9，.github/workflows/macos-release.yml）。
# 和 --ci 一起用时只有 arm64。
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "$(uname)" == "Darwin" ]] || { echo "needs macOS with Xcode" >&2; exit 1; }
ci=0
macos_only=0
args=()
for a in "$@"; do
  case "$a" in
    --ci) ci=1 ;;
    --macos) macos_only=1 ;;
    *) args+=("$a") ;;
  esac
done
out="${args[0]:-target/apple}"
profile=mobile
if (( macos_only )); then
  targets=(aarch64-apple-darwin)
  (( ci )) || targets+=(x86_64-apple-darwin)
elif (( ci )); then
  targets=(aarch64-apple-ios-sim aarch64-apple-darwin)
else
  targets=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin)
fi

# 最低系统版本和 Swift 包（下面的 Package.swift：iOS 16、macOS 13）一致。不设时 rustc 链接 iOS 10，C 依赖（aws-lc）却按
# SDK 的最新版本编，真机的 cdylib 链接时缺 `___chkstk_darwin`（2026-10-27 mobile.yml 在 main 上的失败）。
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export MACOSX_DEPLOYMENT_TARGET=13.0

rustup target add "${targets[@]}"
for t in "${targets[@]}"; do
  case "$t" in
    *-apple-darwin) cargo build -p desktop --lib --profile "$profile" --target "$t" ;;
    *) cargo build -p client-core --lib --profile "$profile" --target "$t" ;;
  esac
done
lib() {
  case "$1" in
    *-apple-darwin) echo "target/$1/$profile/libdesktop.a" ;;
    *) echo "target/$1/$profile/libclient_core.a" ;;
  esac
}

rm -rf "$out"
mkdir -p "$out/sim" "$out/macos" "$out/headers"
macos_libs=("$(lib aarch64-apple-darwin)")
(( ci )) || macos_libs+=("$(lib x86_64-apple-darwin)")
if (( ! macos_only )); then
  sim_libs=("$(lib aarch64-apple-ios-sim)")
  (( ci )) || sim_libs+=("$(lib x86_64-apple-ios)")
fi
# 多个架构合成一个胖库；--ci 只有一个架构，直接复制。
merge() {
  local dest="$1"
  shift
  if (( $# == 1 )); then cp "$1" "$dest"; else lipo -create "$@" -output "$dest"; fi
}
(( macos_only )) || merge "$out/sim/libclient_core.a" "${sim_libs[@]}"
# xcframework 里每个切片的库同名：macOS 的 libdesktop 也叫 libclient_core.a。
merge "$out/macos/libclient_core.a" "${macos_libs[@]}"

# 绑定按本机编的 libdesktop 生成（读接口元数据，不用交叉编译）。
cargo build -p desktop --lib
mkdir -p "$out/bindings/swift"
cargo run -q -p client-core --features bindgen --bin uniffi-bindgen -- \
  generate target/debug/libdesktop.dylib --language swift --out-dir "$out/bindings/swift" --no-format
cp "$out/bindings/swift/ThinktinCoreFFI.h" "$out/bindings/swift/ThinktinDesktopFFI.h" "$out/headers/"
cat > "$out/headers/module.modulemap" <<'MAP'
module ThinktinCoreFFI {
    header "ThinktinCoreFFI.h"
    header "ThinktinDesktopFFI.h"
    export *
}
MAP

pkg="$out/ThinktinCore"
mkdir -p "$pkg/Sources/ThinktinCore"
slices=()
if (( ! macos_only )); then
  (( ci )) || slices+=(-library "$(lib aarch64-apple-ios)" -headers "$out/headers")
  slices+=(-library "$out/sim/libclient_core.a" -headers "$out/headers")
fi
slices+=(-library "$out/macos/libclient_core.a" -headers "$out/headers")
xcodebuild -create-xcframework "${slices[@]}" -output "$pkg/ThinktinCoreFFI.xcframework"
cp "$out/bindings/swift/ThinktinCore.swift" "$pkg/Sources/ThinktinCore/"
# 生成的文件最后一行没有换行：`#endif` 前面补一个，不然接在 `// swiftlint:enable all` 后面成了注释。
{
  echo "#if os(macOS)"
  sed 's/ThinktinDesktopFFI/ThinktinCoreFFI/g' "$out/bindings/swift/ThinktinDesktop.swift"
  printf '\n#endif\n'
} > "$pkg/Sources/ThinktinCore/ThinktinDesktop.swift"
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
# macOS 上多了 desktop 的依赖：清单按两边的合集列（名字还叫 client-core，App 的“开源许可”页面按它认）。
python3 tools/licenses/licenses.py cargo -p client-core -p desktop --subject client-core \
  --out "$pkg/Sources/ThinktinCore/Licenses"
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

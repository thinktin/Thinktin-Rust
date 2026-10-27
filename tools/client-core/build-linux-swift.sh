#!/usr/bin/env bash
# 在 Linux 上把 client-core 打成 Swift 包 `ThinktinCore`（WBS 12.1），给没有 Xcode 的环境（云端会话、CI 的
# ubuntu 任务）编译和测试 ThinktinKit 的纯 Swift 部分和 ThinktinCore 适配层。接口和 build-apple.sh 打出来的
# 包完全一样（同一份 UniFFI 绑定），只是二进制换成本机的 libclient_core.so。
#
#   tools/client-core/build-linux-swift.sh [输出目录] [--release] [--desktop]
#
# 输出：<out>/ThinktinCore/（Package.swift、系统库模块 ThinktinCoreFFI、ThinktinCore.swift）。
# 用的时候：swift build / swift test 照常；运行测试时动态库要在 LD_LIBRARY_PATH 里（脚本最后会打印）。
#
# --desktop：打 macOS App 用的那种包（14.5，默认输出 target/linux-desktop）：库换成 libdesktop（里面也有
# client-core），绑定按库生成两份（ThinktinCore.swift、ThinktinDesktop.swift）放进同一个 Swift 模块，两个头文件
# 放进同一个 C 模块 ThinktinCoreFFI（共用的定义有防重复的宏）。build-apple.sh 的 macOS 切片也是这个样子。
set -euo pipefail
cd "$(dirname "$0")/../.."
profile=debug
desktop=0
args=()
for a in "$@"; do
  case "$a" in
    --release) profile=release ;;
    --desktop) desktop=1 ;;
    *) args+=("$a") ;;
  esac
done
[[ "$(uname)" == "Linux" ]] || { echo "needs Linux; on macOS use build-apple.sh" >&2; exit 1; }
if (( desktop )); then
  crate=desktop
  libname=desktop
  out="${args[0]:-target/linux-desktop}"
else
  crate=client-core
  libname=client_core
  out="${args[0]:-target/linux}"
fi

if [[ "$profile" == "release" ]]; then
  cargo build -p "$crate" --lib --release
else
  cargo build -p "$crate" --lib
fi
libdir="$(pwd)/target/$profile"
[[ -f "$libdir/lib$libname.so" ]] || { echo "missing $libdir/lib$libname.so" >&2; exit 1; }

if (( desktop )); then
  rm -rf "$out/bindings/swift"
  mkdir -p "$out/bindings/swift"
  cargo run -q -p client-core --features bindgen --bin uniffi-bindgen -- \
    generate "$libdir/libdesktop.so" --language swift --out-dir "$out/bindings/swift" --no-format
else
  tools/client-core/gen-bindings.sh "$out/bindings"
fi

pkg="$out/ThinktinCore"
rm -rf "$pkg"
mkdir -p "$pkg/Sources/ThinktinCoreFFI" "$pkg/Sources/ThinktinCore"
cp "$out/bindings/swift/ThinktinCoreFFI.h" "$pkg/Sources/ThinktinCoreFFI/"
cp "$out/bindings/swift/ThinktinCore.swift" "$pkg/Sources/ThinktinCore/"
if (( desktop )); then
  cp "$out/bindings/swift/ThinktinDesktopFFI.h" "$pkg/Sources/ThinktinCoreFFI/"
  cat > "$pkg/Sources/ThinktinCoreFFI/module.modulemap" <<'MAP'
module ThinktinCoreFFI {
    header "ThinktinCoreFFI.h"
    header "ThinktinDesktopFFI.h"
    link "desktop"
    export *
}
MAP
  # 两份绑定在同一个 C 模块里：desktop 那份改成 import ThinktinCoreFFI。
  sed 's/ThinktinDesktopFFI/ThinktinCoreFFI/g' "$out/bindings/swift/ThinktinDesktop.swift" \
    > "$pkg/Sources/ThinktinCore/ThinktinDesktop.swift"
else
  cat > "$pkg/Sources/ThinktinCoreFFI/module.modulemap" <<'MAP'
module ThinktinCoreFFI {
    header "ThinktinCoreFFI.h"
    link "client_core"
    export *
}
MAP
fi
# 包资源（许可证）给外面的模块用：SwiftPM 生成的 Bundle.module 是 internal 的。
cat > "$pkg/Sources/ThinktinCore/Resources.swift" <<'RES'
import Foundation

/// client-core 依赖的 crate 的许可证清单（`Licenses/NOTICES.md`、`inventory.json`、`texts/`）。
public enum ThinktinCoreResources {
    public static let bundle: Bundle = Bundle.module
}
RES
# 依赖的 crate 的许可证清单（和 build-apple.sh 一样放进包资源，App 的“开源许可”页面读）。
# --desktop 时按 client-core 和 desktop 的合集列（名字还叫 client-core，和 build-apple.sh 一样）。
if (( desktop )); then
  python3 tools/licenses/licenses.py cargo -p client-core -p desktop --subject client-core \
    --out "$pkg/Sources/ThinktinCore/Licenses"
else
  python3 tools/licenses/licenses.py cargo -p client-core --subject client-core --out "$pkg/Sources/ThinktinCore/Licenses"
fi
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

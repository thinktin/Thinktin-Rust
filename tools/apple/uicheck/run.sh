#!/usr/bin/env bash
# Linux 上对 ThinktinUI 和 iOS App target 做类型检查（WBS 12.1，docs/ios.md 第 7 节）。
#
# 云端会话没有 Xcode，SwiftUI / UIKit / AppKit / Security / OSLog 用 Stubs/ 里的桩模块代替（签名照 iOS 17 / macOS 14 SDK），
# 所以这里只能发现类型错误、并发检查的问题，不能代替 macOS CI 上的真实编译和模拟器测试。推送前跑一遍，省一轮 CI。
#
#   tools/apple/uicheck/run.sh            UIKit 版（ThinktinUI + App target + 测试）
#   tools/apple/uicheck/run.sh appkit     AppKit 版（ThinktinUI 的 macOS 代码路径）
#   tools/apple/uicheck/run.sh test       UIKit 版之外再跑 ThinktinUITests（逻辑测试有意义，视图测试只证明能编；
#                                         桩的 sizeThatFits 总是返回提议尺寸，“抽屉：打开和关闭”在这里会失败，以 macOS CI 为准）
#
# 前提：target/linux/ThinktinCore 已生成（tools/client-core/build-linux-swift.sh）。
# 桩模块缺某个 SwiftUI API 时会报“找不到成员”：照 Apple 文档的签名在 Stubs/ 里补上，别为了过检查改 App 代码。
# 补之前先 grep 整个 Stubs/ 有没有同名声明：并行开发的功能各自加桩，合并后重复声明会报 invalid redeclaration。
set -euo pipefail
cd "$(dirname "$0")"
[[ -d ../../../target/linux/ThinktinCore ]] || { echo "先跑 tools/client-core/build-linux-swift.sh target/linux" >&2; exit 1; }
python3 prep.py
case "${1:-uikit}" in
  appkit) UISTUB_PLATFORM=AppKit swift build --build-tests --scratch-path .build-appkit ;;
  test) swift build --build-tests && swift test --skip-build --filter ThinktinUITests ;;
  *) swift build --build-tests ;;
esac

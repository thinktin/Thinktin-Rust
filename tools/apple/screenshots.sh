#!/usr/bin/env bash
# iPhone 模拟器上跑演示模式（Mock 数据，不联网）的 iOS App，按深链打开几个主要页面截图：给人看界面，也是上架截图的底稿。
# 只能在 macOS 上跑（Xcode、模拟器、XcodeGen）。前提：target/apple/ThinktinCore 已生成（build-apple.sh --ci 就够）。
# Codemagic 上是 codemagic.yaml 的 ios-screenshots。
#
#   tools/apple/screenshots.sh [输出目录，默认 target/screenshots]
#
# 每张图都重新启动 App，用环境变量 THINKTIN_OPEN_URL / THINKTIN_OPEN_DRAWER 指定启动后的页面（只有 Debug 构建认，见
# AppConfiguration）：`simctl openurl` 会先弹系统的确认框挡住页面。中文界面，状态栏固定成 9:41、满电。
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "$(uname)" == "Darwin" ]] || { echo "needs macOS with Xcode" >&2; exit 1; }
[[ -d target/apple/ThinktinCore ]] || { echo "先跑 tools/client-core/build-apple.sh target/apple --ci" >&2; exit 1; }
out="${1:-target/screenshots}"
mkdir -p "$out"
(cd apps/apple && xcodegen generate)

# 选中的 Xcode 支持的最新 iOS 运行时里的 iPhone，带 Pro 的优先（屏幕尺寸和上架截图要的一样）。
SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)
export SDK_VERSION
udid=$(xcrun simctl list --json devices available | python3 -c '
import json, os, sys
devices = json.load(sys.stdin)["devices"]
sdk = tuple(int(p) for p in os.environ["SDK_VERSION"].split(".") if p.isdigit())
def version(runtime):
    return tuple(int(p) for p in runtime.rsplit("iOS-", 1)[1].split("-") if p.isdigit())
runtimes = sorted((r for r in devices if ".SimRuntime.iOS-" in r and version(r) <= sdk), key=version, reverse=True)
for runtime in runtimes:
    phones = [d for d in devices[runtime] if d.get("isAvailable", True) and d["name"].startswith("iPhone")]
    phones.sort(key=lambda d: ("Pro" not in d["name"], "Max" in d["name"], d["name"]))
    if phones:
        print(phones[0]["udid"], file=sys.stdout)
        print(phones[0]["name"], runtime, file=sys.stderr)
        sys.exit(0)
sys.exit("no available iPhone simulator")
')
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b

dd="target/screenshots-derived-data"
xcodebuild -project apps/apple/Thinktin.xcodeproj -scheme Thinktin -configuration Debug \
  -destination "id=$udid" -derivedDataPath "$dd" -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build -quiet
app="$dd/Build/Products/Debug-iphonesimulator/Thinktin.app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")
xcrun simctl install "$udid" "$app"
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 \
  --batteryState charged --batteryLevel 100

# 重新启动 App（上一张打开的页面、弹出的面板不会叠到下一张上）。参数是额外给 App 的环境变量（SIMCTL_CHILD_NAME=value）。
launch() {
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  env SIMCTL_CHILD_THINKTIN_MOCK=1 "$@" \
    xcrun simctl launch "$udid" "$bundle" -AppleLanguages "(zh-Hans)" -AppleLocale zh_CN >/dev/null
  sleep 6
}
shot() {
  xcrun simctl io "$udid" screenshot --type=png "$out/$1.png" >/dev/null
  echo "$out/$1.png"
}
open_and_shot() {
  launch "SIMCTL_CHILD_THINKTIN_OPEN_URL=$2"
  shot "$1"
}

# 演示数据里的 id（ThinktinKit 的 DemoData）。
writer=0192f3a0-0000-7000-8000-000000000101
weekly_run=0192f3a0-0000-7000-8000-000000000201
pending_approval=0192f3a0-0000-7000-8000-000000000301
digest_plan=0192f3a0-0000-7000-8000-000000000401
npm_request=0192f3a0-0000-7000-8000-000000000801

launch
shot 01-home
launch SIMCTL_CHILD_THINKTIN_OPEN_DRAWER=1
shot 02-drawer
open_and_shot 03-instance "thinktin://instance/$writer"
open_and_shot 04-run "thinktin://run/$weekly_run"
open_and_shot 05-approvals "thinktin://approvals"
open_and_shot 06-approval "thinktin://approval/$pending_approval"
open_and_shot 07-plan "thinktin://plan/$digest_plan"
open_and_shot 08-inbox "thinktin://inbox"
open_and_shot 09-active "thinktin://active"
open_and_shot 10-vault-request "thinktin://vault/request/$npm_request"
# 深色模式的首页和抽屉。
xcrun simctl ui "$udid" appearance dark
launch
shot 11-home-dark
launch SIMCTL_CHILD_THINKTIN_OPEN_DRAWER=1
shot 12-drawer-dark
xcrun simctl ui "$udid" appearance light

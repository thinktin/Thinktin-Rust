#!/usr/bin/env bash
# iPhone 模拟器上跑演示模式（Mock 数据，不联网）的 iOS App，把改版的每一组页面都打开截图：给人看界面、和改版参考对照
# （每张图对哪几张参考、规范哪一节见 docs/ios-ui-redesign-shots.md），也是上架截图的底稿。主要页面浅色、深色各一张
# （01-home-light.png、01-home-dark.png），其余的只截浅色（一共 71 张）。
# 只能在 macOS 上跑（Xcode、模拟器、XcodeGen）。前提：target/apple/ThinktinCore 已生成（build-apple.sh --ci 就够）。
# Codemagic 上是 codemagic.yaml 的 ios-screenshots。
#
#   tools/apple/screenshots.sh [输出目录，默认 target/screenshots]
#   IOS_RUNTIME=18.6 tools/apple/screenshots.sh   # 用 iOS 18.6 的模拟器看 iOS 17 / 18 的回退
#
# IOS_RUNTIME 是版本号（18、18.6、17.5）：只在那个版本的模拟器里挑。没有那个版本的 iPhone 模拟器时建一台；连运行时都没装时
# 先用 `xcodebuild -downloadPlatform iOS -buildVersion` 下载（几个 GB，这时要写完整的版本号，比如 18.6）。CI 上的触发办法见
# .github/workflows/ios-screenshots.yml 开头（Run workflow 的 ios_runtime，或者推到 ios-screenshots-ios18.6 这样的分支）。
#
# 每张图都重新启动 App，用启动环境变量指定打开的页面（只有 Debug 构建认，见 AppConfiguration；`simctl openurl` 会先弹
# 系统的确认框挡住页面）：THINKTIN_OPEN_URL 是 thinktin:// 深链，THINKTIN_OPEN_SCREEN 是没有深链的页面（首页第一个 Botin 的
# 对话、计划、产出物、观看与接管，设置、新建 Botin 这些 sheet，设置里压进去的几页，首页搜索，首页置顶、隐藏的摆法，页面里
# 本地打开的子页：编辑 Botin、头像、工作区、引擎详情、保险箱的新建表单、设备详情、外观……），THINKTIN_MOCK_EMPTY=1 换成
# 还没有 Botin 的新账号（首页空状态）。每次都设 THINKTIN_SCREENSHOT=1：Botin 的脸不眨眼、不转眼，每次截出来的一样。
# 中文界面，状态栏固定成 9:41、满电；键盘的“滑动输入”介绍事先关掉。系统的长按菜单、左滑、`Menu` 菜单（语音、语言的选项）
# 要真的点，这里截不到。
# macOS 自带的是 bash 3.2：set -u 下别用空数组，紧跟中文标点的变量写成 ${name}。
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "$(uname)" == "Darwin" ]] || { echo "needs macOS with Xcode" >&2; exit 1; }
[[ -d target/apple/ThinktinCore ]] || { echo "先跑 tools/client-core/build-apple.sh target/apple --ci" >&2; exit 1; }
out="${1:-target/screenshots}"
mkdir -p "$out"
(cd apps/apple && xcodegen generate)

# 选中的 Xcode 支持的最新 iOS 运行时里的 iPhone（设了 IOS_RUNTIME 时只在那个版本里挑，比如 18 或 17.5），
# 带 Pro 的优先（屏幕尺寸和上架截图要的一样）。
SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)
export SDK_VERSION
export IOS_RUNTIME="${IOS_RUNTIME:-}"
if [[ -n "$IOS_RUNTIME" && ! "$IOS_RUNTIME" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "IOS_RUNTIME 要写成 18、18.6 这样的版本号，现在是：${IOS_RUNTIME}" >&2
  exit 1
fi
pick_iphone() {
  xcrun simctl list --json devices available | python3 -c '
import json, os, sys
devices = json.load(sys.stdin)["devices"]
sdk = tuple(int(p) for p in os.environ["SDK_VERSION"].split(".") if p.isdigit())
want = tuple(int(p) for p in os.environ["IOS_RUNTIME"].split(".") if p.isdigit())
def version(runtime):
    return tuple(int(p) for p in runtime.rsplit("iOS-", 1)[1].split("-") if p.isdigit())
runtimes = sorted(
    (r for r in devices if ".SimRuntime.iOS-" in r and version(r) <= sdk and version(r)[:len(want)] == want),
    key=version, reverse=True)
for runtime in runtimes:
    phones = [d for d in devices[runtime] if d.get("isAvailable", True) and d["name"].startswith("iPhone")]
    phones.sort(key=lambda d: ("Pro" not in d["name"], "Max" in d["name"], d["name"]))
    if phones:
        print(phones[0]["udid"], file=sys.stdout)
        print(phones[0]["name"], runtime, file=sys.stderr)
        sys.exit(0)
sys.exit("no available iPhone simulator" + (" on iOS " + os.environ["IOS_RUNTIME"] if want else ""))
'
}
# 装好的 IOS_RUNTIME 版本的 iOS 运行时（最新的那个）和它支持的一种 iPhone（带 Pro、不带 Max 的优先，取最新的）：
# 一行“运行时 id<Tab>机型 id<Tab>机型名”；没装时失败。
find_runtime() {
  xcrun simctl list --json runtimes available | python3 -c '
import json, os, sys
want = tuple(int(p) for p in os.environ["IOS_RUNTIME"].split(".") if p.isdigit())
def version(runtime):
    return tuple(int(p) for p in runtime.get("version", "").split(".") if p.isdigit())
runtimes = sorted(
    (r for r in json.load(sys.stdin)["runtimes"]
     if ".SimRuntime.iOS-" in r["identifier"] and r.get("isAvailable", True) and version(r)[:len(want)] == want),
    key=version, reverse=True)
for runtime in runtimes:
    phones = [
        t for t in runtime.get("supportedDeviceTypes", [])
        if t.get("productFamily", "iPhone" if t["name"].startswith("iPhone") else "") == "iPhone"]
    pros = [t for t in phones if "Pro" in t["name"] and "Max" not in t["name"]]
    if pros or phones:
        phone = (pros or phones)[-1]
        print(runtime["identifier"], phone["identifier"], phone["name"], sep="\t")
        sys.exit(0)
sys.exit("iOS " + os.environ["IOS_RUNTIME"] + " runtime is not installed")
'
}
if ! udid=$(pick_iphone); then
  [[ -n "$IOS_RUNTIME" ]] || exit 1
  # 镜像里没有这个版本的 iPhone 模拟器（CI 上常见）：运行时没装就下载，再建一台。
  if ! found=$(find_runtime); then
    echo "下载 iOS ${IOS_RUNTIME} 的模拟器运行时" >&2
    xcodebuild -downloadPlatform iOS -buildVersion "$IOS_RUNTIME"
    found=$(find_runtime)
  fi
  IFS=$'\t' read -r runtime_id device_type device_name <<<"$found"
  echo "新建模拟器：${device_name}（${runtime_id}）" >&2
  udid=$(xcrun simctl create "$device_name" "$device_type" "$runtime_id")
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b
# 第一次弹键盘时系统的“滑动输入”（QuickPath）介绍会盖住半个页面：关掉滑动输入、记成看过介绍。哪一项在这个 iOS 版本上
# 不认都不要紧，失败不管。
xcrun simctl spawn "$udid" defaults write com.apple.keyboard.preferences.plist KeyboardContinuousPathEnabled -bool false \
  >/dev/null 2>&1 || true
xcrun simctl spawn "$udid" defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true \
  >/dev/null 2>&1 || true
xcrun simctl spawn "$udid" defaults write com.apple.Preferences DidShowGestureKeyboardIntroduction -bool true \
  >/dev/null 2>&1 || true
# 键盘开机时读这几项，开着机写进去不生效（2026-11-05 那一轮第一张有键盘的 09-search-light 上还是盖着介绍）：
# 写完重启一次模拟器。
xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
xcrun simctl boot "$udid"
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

# 重新启动 App（上一张打开的页面、弹出的面板不会叠到下一张上）。$1 是 THINKTIN_OPEN_SCREEN，$2 是 THINKTIN_OPEN_URL，
# $3 是 THINKTIN_MOCK_EMPTY；空的 App 不认，都空就是演示数据的首页。引导（12.17）只在有 Botin、没有 key 的账号第一次启动时弹
# （演示数据有 key，新账号没有 Botin，现在都不弹）：启动参数把“看过引导”（OnboardingCheck 的键）写进 UserDefaults 的参数域，
# 以后改了演示数据也不会盖住截图。首页的置顶、隐藏（InstancePreferencesStore 的键）也用参数域盖成“没有”：homepinned 这几张
# 摆的置顶、隐藏会存进模拟器，不盖的话后面每张的首页都带着。等 7 秒：子页一层层打开（每层等转场走完），要几秒。
launch() {
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  env SIMCTL_CHILD_THINKTIN_MOCK=1 SIMCTL_CHILD_THINKTIN_SCREENSHOT=1 \
    "SIMCTL_CHILD_THINKTIN_OPEN_SCREEN=$1" "SIMCTL_CHILD_THINKTIN_OPEN_URL=$2" "SIMCTL_CHILD_THINKTIN_MOCK_EMPTY=$3" \
    xcrun simctl launch "$udid" "$bundle" -AppleLanguages "(zh-Hans)" -AppleLocale zh_CN \
    -cn.thinktin.onboarding.checked YES -cn.thinktin.shell.instancePreferences none >/dev/null
  sleep 7
}
shot() {
  xcrun simctl io "$udid" screenshot --type=png "$out/$1.png" >/dev/null
  echo "$out/$1.png"
}

# 演示数据里的 id（ThinktinKit 的 DemoData）。THINKTIN_OPEN_SCREEN 打开首页第一个实例，演示数据里就是 writer。
writer=0192f3a0-0000-7000-8000-000000000101
weekly_run=0192f3a0-0000-7000-8000-000000000201
pending_approval=0192f3a0-0000-7000-8000-000000000301
digest_plan=0192f3a0-0000-7000-8000-000000000401
npm_request=0192f3a0-0000-7000-8000-000000000801

# 截图清单（每张对哪几张参考、规范哪一节见 docs/ios-ui-redesign-shots.md），一行一张：文件名、截哪几种外观（ld 是浅色和深色，
# l 只截浅色）、THINKTIN_OPEN_SCREEN、THINKTIN_OPEN_URL、THINKTIN_MOCK_EMPTY，“-”是不设，最后一列不写也是不设。按编号排，
# 编号定了不改（对照文件和以前的截图都按名字找），新页面往后加。
shots="
00-home-empty ld - - 1
01-home ld - -
02-conversation ld conversation -
03-instance ld - thinktin://instance/${writer}
04-plans ld plans -
05-artifacts ld artifacts -
06-settings ld settings -
07-vault-request l - thinktin://vault/request/${npm_request}
08-adopt ld adopt -
09-search ld search -
10-approval l - thinktin://approval/${pending_approval}
11-inbox ld - thinktin://inbox
12-active ld - thinktin://active
13-run ld - thinktin://run/${weekly_run}
14-plan ld - thinktin://plan/${digest_plan}
15-approvals ld - thinktin://approvals
16-teams l teams -
17-new-task l newtask -
18-onboarding l onboarding -
19-connections ld connections -
20-instance-screen ld instancescreen -
21-permissions l permissions -
22-subscription l subscription -
23-import-memory l importmemory -
24-feedback l feedback -
25-home-pinned ld homepinned -
26-hidden-botins l hiddenbotins -
27-home-all-hidden l homeallhidden -
28-conversation-find l conversationfind -
29-botin-edit l botinedit -
30-botin-avatar l botinavatar -
31-workspace l workspace -
32-primary-botin l primarybotin -
33-engines l engines -
34-engine-detail l enginedetail -
35-artifacts-media l artifactsmedia -
36-connected l connected -
37-connection-detail l connectiondetail -
38-account l account -
39-usage l usage -
40-model-keys l modelkeys -
41-vault l vault -
42-vault-login l vaultlogin -
43-vault-card l vaultcard -
44-vault-contact l vaultcontact -
45-permission-rule l permissionrule -
46-devices l devices -
47-device-detail l devicedetail -
48-computer-detail l computerdetail -
49-appearance l appearance -
50-language l language -
51-haptics l haptics -
52-primary-botin-empty l primarybotin - 1
53-plans-empty l allplans - 1
54-settings-bottom l settingsbottom -
"

for appearance in light dark; do
  xcrun simctl ui "$udid" appearance "$appearance"
  # 清单从 3 号文件描述符读，循环里的 simctl 读标准输入也吃不掉它。
  while read -r name modes screen url empty <&3; do
    if [[ -z "$name" ]]; then continue; fi
    if [[ "$appearance" == dark && "$modes" != ld ]]; then continue; fi
    if [[ "$screen" == - ]]; then screen=""; fi
    if [[ "$url" == - ]]; then url=""; fi
    if [[ "$empty" == - ]]; then empty=""; fi
    launch "$screen" "$url" "$empty"
    shot "${name}-${appearance}"
  done 3<<EOF
${shots}
EOF
done
xcrun simctl ui "$udid" appearance light

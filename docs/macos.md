# macOS App

WBS 14.5–14.9。Mac 上的 ThinkTin：菜单栏常驻，后台跑电脑端的工具服务（Rust 的 `desktop`，见 [电脑工具](desktop.md)），
用户的 agent 经设备中继、按手机给的授权用这台电脑；主窗口是和 iPhone 一样的对话、计划界面（ThinktinUI 复用）。
配对和高危审批的协议见 [配对](pairing.md)，手机那一侧见 [iOS](ios.md) 第 6.5 节。

## 1. 结构

| 位置 | 内容 |
| --- | --- |
| `apps/apple/ThinktinMac/App/` | 入口（`ThinktinMacApp`：菜单栏 + 主窗口）、App 代理、装配（`MacEnvironment`）、中继地址和状态目录（`MacConfiguration`） |
| `apps/apple/ThinktinMac/Platform/` | 钥匙串里的配对密钥、二维码、截图 / 键鼠 / 打开（`MacNativeTools`）、系统权限和登录项、自动更新 |
| `apps/apple/ThinktinMac/Views/` | 菜单栏图标和面板、权限引导 |
| `ThinktinKit/.../Computer/Host/` | 和平台无关的部分（Linux 上测）：`ComputerHost` 协议、菜单栏的视图模型、跟着登录状态建服务（`ComputerHostLifecycle`）、按键解析（`KeyCombination`）、截图坐标（`ScreenshotGeometry`） |
| `ThinktinKit/Sources/ThinktinDesktopAdapter/` | UniFFI 的 `DesktopService` 接上 `ComputerHost`（`DesktopServiceHost`） |
| `ThinktinUI/Screens/Computer/ComputerHostPanel.swift` | 菜单栏里“手机控制”那一块 |

和 iOS 共用 `Thinktin/App/AppConfiguration.swift`、`Thinktin/Platform/KeychainSessionStore.swift` 两个文件（project.yml 里
`ThinktinMac` 的 sources 直接引用）。ThinktinCore 的 macOS 切片是 libdesktop（里面也有 client-core），见 desktop.md 第 4 节。

## 2. 运行方式

- **菜单栏常驻**：`LSUIElement`，没有程序坞图标。菜单栏是第一个场景，主窗口不是，所以启动时不弹窗口；没登录时
  `MacEnvironment.start()` 请求打开主窗口去登录。主窗口从菜单“打开 ThinkTin”打开，关掉不退出。
- **工具服务跟着登录走**（`ComputerHostLifecycle`）：登录了按这台电脑的设备 id 建 `DesktopServiceHost`，状态目录是
  `Application Support/Thinktin/desktop/<设备 id>/`（配对的手机、能力令牌、审计日志）；退出登录、冻结、要升级时停掉、丢掉。
  每次登录是一台新设备，之前的配对不带过来。
- **开关记在本机**：用户点开始 / 停止按设备 id 记进 `UserDefaults`；开机（登录项拉起）、重新登录、解冻后照着开。
  退出登录这种被动的停止不改记下的开关。
- **“正在被控制”的提示**（14.6）：配好手机、连着中继时菜单栏图标换成“电脑和手机”（`macbook.and.iphone`），面板里一键停止。
- **Debug 默认 Mock**：和 iOS 一样（`THINKTIN_MOCK`），菜单栏里是假的服务（`FakeComputerHost`），不连中继。scheme 里勾上
  `THINKTIN_MOCK=0` 连真接口和真中继。

## 3. 系统工具（14.3、14.4）

文件和命令由 Rust 做；要系统接口的在 `MacNativeTools`：

| 工具 | 实现 | 要的权限 |
| --- | --- | --- |
| `computer_screenshot` | ScreenCaptureKit 截主显示器（`SCScreenshotManager`），JPEG，长边最多 1568 像素 | 屏幕录制 |
| `computer_click` | `CGEvent` 鼠标事件；坐标是最近一张截图的像素，按 `ScreenshotGeometry` 换回点 | 辅助功能 |
| `computer_type` | `CGEvent` 带 Unicode 字符串，十几个字符一组；换行按回车键 | 辅助功能 |
| `computer_key` | `KeyCombination` 解析 `cmd+shift+t` 这类写法成虚拟键码 | 辅助功能 |
| `computer_open` | `NSWorkspace`：https 网页、绝对路径的文件、bundle id 的应用 | 无 |

连上中继时报给平台的工具随权限变（`available()`）：没给屏幕录制就没有截图。工具服务在 `hello` 里报一次，所以打开权限后
要停止再开始一次手机控制（面板上有提示）；屏幕录制还要重新打开 App 才生效（系统的规定）。

工具服务在调用前核对过手机的授权和前台应用（policy.rs）。这里再守两条它看不到的：

- **点击落在别的应用的窗口上时拒绝**：授权按前台应用给，点到别的应用（第 0 层的普通窗口，按 `CGWindowListCopyWindowInfo`
  的进程 id 比）就越权了。菜单栏、程序坞这些不是第 0 层，不拦。
- **`computer_open` 不打开“打开就会运行”的文件**：应用包、可执行文件、脚本、安装包、`.command`、`.terminal`、自动操作这类，
  按扩展名和文件属性挡掉，让 agent 改用要手机批准的 `computer_run`。

前台应用在主线程上跟着 `NSWorkspace.didActivateApplicationNotification` 记下来，工具服务的线程读；ThinkTin 自己的窗口
（面板上可能正显示着配对二维码）不进截图。

## 4. 配对密钥和二维码（14.8）

`KeychainPairingKey`：P-256，有 Secure Enclave（Apple 芯片、带 T2 的 Intel Mac）时私钥在芯片里，钥匙串里存的是只在这台 Mac
上能用的句柄；没有或建不起来（没签名的开发版）时用软件密钥，也存钥匙串（`AfterFirstUnlockThisDeviceOnly`，不进 iCloud）。
出二维码时用户就在电脑前，不再要求触控 ID。一台 Mac 一把，换账号也用它；删掉钥匙串里 `cn.thinktin.pairing-key` 就是换新的，
之前配的手机要重新配对。二维码用 CoreImage 的 `CIQRCodeGenerator` 画（纠错等级 M）。

## 5. 权限引导和登录项（14.6、14.7）

菜单栏面板的“系统权限”一节：屏幕录制（`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`）、辅助功能
（`AXIsProcessTrusted` / 带提示的 `AXIsProcessTrustedWithOptions`），没给时“去打开”弹系统提示或打开系统设置的对应页。
系统不发权限变化的通知，面板开着时每两秒查一次。“开机时自动打开”是 `SMAppService.mainApp`；要用户在系统设置里批准时
（`requiresApproval`）给一个去设置的按钮。

## 6. 分发（14.9）

Developer ID 签名、公证后在官网分发，不上 Mac App Store：要控制别的应用、读写手机授权的任意目录、执行用户批准的命令，
App Sandbox 里做不了。开 Hardened Runtime（公证要求），不用额外的例外。

**发版**：打 `macos-v<版本>` 标签，`.github/workflows/macos-release.yml` 跑：`build-apple.sh --macos`（arm64 + x86_64）→
xcodegen → Developer ID 归档、导出 → `notarytool` 公证、`stapler` 钉上 → zip → Sparkle 签名、生成 `appcast.xml` → 发到这个标签的
GitHub Release。手动触发时不发布；没配证书时只做不签名的归档，验证能编。构建号是工作流的运行序号，Sparkle 按它比新旧。

**自动更新**（Sparkle 2.6.4，`MacUpdater`）：Info.plist 的 `SUFeedURL`、`SUPublicEDKey` 由构建设置 `SPARKLE_FEED_URL`
（默认 `https://download.thinktin.cn/mac/appcast.xml`）、`SPARKLE_PUBLIC_ED_KEY`（默认空）展开。公钥空着时不启动更新器，
菜单里也没有“检查更新”。签更新包用工程钉死的 Sparkle 包（SwiftPM 按校验和取）里带的 `generate_appcast`。

**要准备的（部署环境，第一次发版前）**：

1. Apple Developer 账号里建“Developer ID Application”证书，导出带私钥的 .p12，base64 后放进 GitHub 的 `macos-release` 环境：
   `MACOS_SIGNING_P12_BASE64`、`MACOS_SIGNING_P12_PASSWORD`、`APPLE_TEAM_ID`。
2. 公证用 App Store Connect API key（和 iOS 发版同一把）：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_P8_BASE64`。
3. Sparkle 的 EdDSA 密钥：在 Mac 上跑 Sparkle 的 `generate_keys`（生成在登录钥匙串里），`generate_keys -x <文件>` 导出私钥，
   放进 `SPARKLE_ED_PRIVATE_KEY`；公钥（`generate_keys -p`）放进仓库变量 `SPARKLE_PUBLIC_ED_KEY`。私钥丢了，装好的 App 就再也
   收不到更新，要另外备份。
4. 更新源：定下域名后把每次发版的 `appcast.xml` 放到 `SPARKLE_FEED_URL`（OSS + CDN 就行；改地址时设仓库变量 `SPARKLE_FEED_URL`）。
   更新包默认从 GitHub Release 下载，要放在自己的存储上时设 `MACOS_DOWNLOAD_URL_PREFIX` 并把 zip 一起传上去。
5. 正式的中继地址（`THINKTIN_RELAY_URL`，默认 `wss://relay.thinktin.cn/v1/connect`）和接口地址按部署的域名改 project.yml。

## 7. 构建与检查

- **Linux（云端会话）**：`tools/client-core/build-linux-swift.sh --desktop` 打 libdesktop 那种 ThinktinCore，然后
  `tools/apple/uicheck/run.sh appkit` 用桩模块（AppKit、ScreenCaptureKit、ServiceManagement、ApplicationServices、CoreImage、
  Sparkle……）给 ThinktinUI 的 macOS 路径和整个 `ThinktinMac` target 做类型检查。只能发现类型错误和并发检查的问题，
  以 macOS CI 的真实编译为准。逻辑在 ThinktinKit 里测（`swift test`，`THINKTIN_DESKTOP=1` 时连 ThinktinDesktopAdapterTests）。
- **CI**：`ios.yml` 的 kit-linux 作业跑 ThinktinDesktopAdapterTests；app-macos 作业 xcodegen 后编 `ThinktinMac`
  （`CODE_SIGNING_ALLOWED=NO`）。截图、键鼠要系统权限，CI 上不跑。
- **本机（Mac）**：`tools/client-core/build-apple.sh target/apple`，`cd apps/apple && xcodegen generate`，Xcode 里选 ThinktinMac
  scheme 运行。第一次跑要在系统设置里给屏幕录制、辅助功能权限（每次重新签名的开发版可能要重新给）。

## 8. 还没做的

- 真机上没跑过（云端会话没有 Mac）：截图、键鼠、登录项、Secure Enclave 密钥、Sparkle 都要在 Mac 上过一遍；第一次 CI 编译
  可能还有桩模块没覆盖到的 SDK 差异要修。
- 电脑发给手机的审批说明还是英文的（`desktop` 按工具拼的），跟着 App 的语言设置本地化。
- Mac 上的推送（审批、收件箱）：现在 Mac 不注册 APNs，审批都在手机上做；要的话加 `aps-environment` 和注册。
- 正在执行工具时的提示（现在只按“配好手机、连着中继”亮图标）：工具服务没有“开始 / 结束调用”的回调，要加到 `DesktopObserver`。

# Windows 电脑端

WBS 14.10–14.14。Windows 上的 ThinkTin：托盘常驻，后台跑电脑端的工具服务（Rust 的 `desktop`，见 [电脑工具](desktop.md)），
用户的 agent 经设备中继、按手机给的授权用这台电脑。和 [macOS App](macos.md) 对应，但整个 App 用 Rust 写
（egui 窗口 + 托盘），`desktop` 库直接链接，不经 UniFFI。对话和计划的界面不在这一期（在手机上做）。
配对和高危审批的协议见 [配对](pairing.md)。

## 1. 结构

| 位置 | 内容 |
| --- | --- |
| `apps/windows/src/main.rs` | 入口：`--background`（登录项拉起时不显示窗口）、DPI、日志、起后台和窗口 |
| `apps/windows/src/service.rs` | 后台：client-core 的 `Api`（登录、设备）和 `desktop::Desktop`（连中继、把关、执行）跑在 tokio 上；界面读快照 `Shared` |
| `apps/windows/src/app.rs` | 窗口：登录页；手机控制（状态、开始 / 停止、正在执行什么、停下的原因）、手机（配对二维码、解除配对）、授权列表、设置（开机自启、退出登录） |
| `apps/windows/src/tray.rs` | 托盘图标和菜单（`tray-icon`）：打开窗口、开始 / 停止、退出；图标颜色随状态 |
| `apps/windows/src/store.rs` | 本机状态 `state.bin`：登录会话、配对私钥、手机控制的开关；JSON 经 DPAPI 加密 |
| `apps/windows/src/platform.rs` | DPAPI、注册表 Run 键（开机自启）、系统语言、起不来时的提示框 |
| `apps/windows/src/{texts,fonts,qr,icon,config}.rs` | 中英文文案、系统中文字体、二维码、程序里画的图标、地址和目录 |
| `crates/desktop/src/windows.rs` | Windows 的系统工具（见第 3 节） |

数据在 `%LOCALAPPDATA%\Thinktin\`：`state.bin`、`logs\thinktin.log`、`desktop\<设备 id>\`（配对的手机、能力令牌、审计日志 `audit.jsonl`）。
接口和中继的地址编译时由 `THINKTIN_API_URL`、`THINKTIN_RELAY_URL` 定（默认 `https://api.thinktin.cn`、
`wss://relay.thinktin.cn/v1/connect`），运行时同名环境变量可以临时换。

## 2. 运行方式

- **托盘常驻**：窗口关掉是收进托盘，托盘菜单的“退出”才退出。`--background` 启动时不显示窗口（开机自启用）。
- **工具服务跟着登录走**：登录了按这台电脑的设备 id 建 `Desktop`，状态目录按设备 id 分；退出登录、会话失效（远程下线）时停掉。
  每次登录是一台新设备，之前的配对不带过来。
- **开关记在本机**（`control_on`，按设备 id）：用户点开始 / 停止记下来；启动（含开机自启）、重新登录后照着开。被动的停止不改。
- **“正在被控制”**：托盘图标灰（未连接）、蓝（已连接）、橙（agent 正在执行工具，等手机批准的不算）；窗口里有状态行和正在执行的工具名；
  点“停止”马上断开。这台电脑在别处又连了一次（中继关 4009）时停下并提示，不自动重连。
- **语言**：按系统界面语言，中文或英文；接口请求带对应的 `Accept-Language`。egui 自带字体没有中文，启动时加载系统的微软雅黑（没有就黑体、宋体）。

## 3. 系统工具（14.3、14.4 的 Windows 版）

文件和命令由 `desktop` 的 `FileTools` 做（Windows 上命令走 PowerShell `-NoProfile -NonInteractive -Command`，不开控制台窗口，
输出按 UTF-8 收，原生程序的退出码带回来；删除进回收站 `SHFileOperationW`）。要系统接口的在 `crates/desktop/src/windows.rs`：

| 工具 | 实现 | 说明 |
| --- | --- | --- |
| `computer_screenshot` | GDI `BitBlt` 主显示器（`CAPTUREBLT`，含分层窗口），缩到长边 1568，JPEG 80 | 进程按显示器 DPI 算像素（`SetProcessDpiAwarenessContext`），截图和点击用同一套坐标 |
| `computer_click` | `SendInput` 绝对坐标（0–65535 铺满主显示器）；坐标按最近一张截图换算（`screenshot::Geometry`） | 点到的窗口不属于前台程序时拒绝（`WindowFromPoint` 的根窗口进程 id 和 `GetForegroundWindow` 的比） |
| `computer_type` | `SendInput` 的 `KEYEVENTF_UNICODE`，换行按回车、制表按 Tab，16 个字符一组 | |
| `computer_key` | `keys::parse` 解析 `ctrl+shift+t` 这类写法（`cmd` / `win` / `super` 是 Win 键，不是 Ctrl）；字符键经 `VkKeyScanW` 查当前键盘布局 | 方向键、Home / End / 翻页、Insert / Delete 带扩展键标志 |
| `computer_open` | `ShellExecuteW`：https 网页、绝对路径的文件、程序名（`chrome.exe`，经 App Paths / PATH 解析） | 打开就会运行的文件（exe、bat、cmd、msi、ps1、vbs、js、lnk、reg、hta、jar、py……）不开，让 agent 用要手机批准的 `computer_run` |
| 前台应用 | `GetForegroundWindow` 所属进程的程序名（小写，`QueryFullProcessImageNameW`） | 手机授权页“应用”一栏填的就是这个，比如 `chrome.exe`、`notepad.exe` |

Windows 没有 macOS 那样的屏幕录制、辅助功能权限开关，所以这几个工具一直报给平台。管理员权限的窗口（UIPI）收不到普通进程发的输入，
锁屏和 UAC 的安全桌面截不了图，这些在调用时报错给 agent。ThinkTin 自己的窗口（可能正显示配对二维码）现在没有从截图里去掉。

路径：手机授权里的目录写 `C:\Users\me\Documents` 这种；client-core 的 `capability_allows_path` 认盘符、UNC 共享、两种分隔符、不分大小写，
`policy::resolve` 把 `canonicalize` 加的 `\\?\` 去掉。

## 4. 配对密钥和二维码

配对私钥是软件密钥（P-256，`desktop::SoftwareKey`），随会话一起放在 `state.bin` 里，经 DPAPI 加密（只有这个 Windows 用户在这台电脑上能解）。
没有 Secure Enclave 那样的硬件保护；以后可以换成 TPM（CNG 的 Platform Crypto Provider）。一台电脑一把，换账号也用它；
删掉 `state.bin` 就是换新的，之前配的手机要重新配对。二维码用 `qrcode` 画成 egui 的纹理显示，有效 10 分钟，窗口上有倒计时。

## 5. 开机自启

设置里的“开机时在后台启动”写注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，值 `ThinkTin` = `"<exe>" --background`。
不需要管理员权限，用户在任务管理器的“启动应用”里也能关。

## 6. 分发（14.14）

`.github/workflows/windows-release.yml`：打 `windows-v<版本>` 标签时在 windows-latest 上 `cargo build --release`，用 Inno Setup
（GitHub 的 Windows 机器自带 `iscc`）按 `apps/windows/installer/thinktin.iss` 打安装包 `ThinkTin-Setup-<版本>.exe`
（装到 `%LOCALAPPDATA%\Programs\ThinkTin`，不要管理员权限；可选勾上开机自启），再发到这个标签的 GitHub Release。
手动触发时只构建不发布。

**要准备的（第一次发版前）**：

1. 代码签名证书（没有签名的话 SmartScreen 会拦）：放进 GitHub 的 `windows-release` 环境：`WINDOWS_SIGNING_PFX_BASE64`、
   `WINDOWS_SIGNING_PFX_PASSWORD`；工作流有这两个时用 `signtool` 给 exe 和安装包签名（时间戳 DigiCert）。EV 证书或 Azure Trusted Signing
   要另外改签名那一步。
2. 自动更新还没做：先在安装包里带版本号，官网放最新的安装包；以后和安卓的 13.12 一样做应用内检查更新（静态的更新清单）。
3. 正式的接口和中继地址按部署的域名改 `apps/windows/src/config.rs` 的默认值（或者构建时设 `THINKTIN_API_URL`、`THINKTIN_RELAY_URL`）。

## 7. 构建与检查

- **Linux（云端会话）**：`cargo clippy -p desktop -p thinktin-windows --all-targets`、`cargo test -p desktop -p thinktin-windows`
  跑跨平台的部分（文件、命令、按键解析、截图编码、本机状态、二维码、图标）。装上 `gcc-mingw-w64-x86-64` 和
  `rustup target add x86_64-pc-windows-gnu` 后，设 `CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc`、`AR_x86_64_pc_windows_gnu=x86_64-w64-mingw32-ar`、
  `CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc`，就能 `cargo clippy --target x86_64-pc-windows-gnu` 检查 Windows 专有的代码、
  `cargo build --release --target x86_64-pc-windows-gnu` 出一个 MinGW 链接的 exe（能跑，但正式发的是 MSVC 的）。
- **CI**：`.github/workflows/windows.yml` 在 windows-latest 上 fmt、clippy、`cargo test -p desktop -p thinktin-windows`（desktop 的端到端测试要
  平台和沙箱，只在 Linux 上跑）、release 构建并上传未签名的 exe。`main` / `backend-core` 的推送和 PR 上相关路径变了就跑，也可以手动触发。
- **本机（Windows）**：装 Rust（MSVC 工具链），`cargo run -p thinktin-windows`。联调本地服务端：`THINKTIN_API_URL=http://127.0.0.1:8080
  THINKTIN_RELAY_URL=ws://127.0.0.1:8081/v1/connect cargo run -p thinktin-windows`。日志在 `%LOCALAPPDATA%\Thinktin\logs\thinktin.log`
  （`THINKTIN_LOG=debug` 更详细）。

## 8. 还没做的

- 真机上没跑过（云端会话没有 Windows）：托盘、窗口、DPAPI、注册表、截图、键鼠、ShellExecute、字体都要在 Windows 上过一遍；
  第一次在 windows-latest 上编 MSVC 目标可能还有要修的。
- 对话和计划的主窗口（macOS 上复用 ThinktinUI）：Windows 上要另写，先不做。
- Windows 上的推送（审批、收件箱）：和 Mac 一样，审批都在手机上做。
- 只开一个实例：开了两个时第二个连上中继会把第一个顶掉（4009），界面会提示；还没加互斥量拦第二个进程。
- 截图没有排除 ThinkTin 自己的窗口；多显示器只截主显示器（和 Mac 一样）。
- 配对密钥没有硬件保护（TPM），见第 4 节。
- 安装包的图标、代码签名、自动更新（第 6 节）。

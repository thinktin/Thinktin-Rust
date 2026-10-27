# claude/windows-version-dev-vafc9z

目标：Windows 电脑端（架构方案 8.6 里“暂不做”的那一项）。和 macOS 端对齐：托盘常驻的电脑端工具服务（Rust 的 `desktop`，经设备中继让用户的 agent 用这台电脑）、登录、手机配对二维码、能力令牌和高危审批把关、开机自启、安装包分发。对话和计划的主窗口（macOS 上复用 ThinktinUI）不在这一期。

认领：Windows 会话（session_012PgAxFAJsLo683tK5xbEqo）在做，2026-10-27 起。后端 `DevicePlatform` 加 `windows`、`desktop` 库跨平台这两处会碰 `crates/**`，别的分支如果也要改这些地方，请在这里记一句。

已完成：
- 分支与进度文件（本文件）。
- **后端认 Windows 是电脑**：`DevicePlatform::Windows` + `is_computer()`（中继、设备消息方向、网关登录唤醒等电脑的运行、执行器的提示文案），迁移 `0023_windows_devices.sql` 放宽 `devices.platform` 的约束；client-core 的 `capability_allows_path` / `capability_message` 认 Windows 路径（盘符、UNC、两种分隔符、不分大小写、`\\?\` 前缀，`DirPath`）；iOS / 安卓授权页的目录校验也收 `C:\…`（没法在这里跑 Swift / Gradle，改动只有几行）。`cargo test` 过（store、relay、gateway、client-core、orchestrator、desktop）。
- **`desktop` 库跨平台**：命令在 Windows 上走 PowerShell（不开控制台、UTF-8 输出、带回原生退出码），删除进回收站（`SHFileOperationW`），`policy::resolve` 去掉 `\\?\`，`computer_open` 按 `Path::is_absolute` 分路径和应用；新模块 `keys`（按键写法解析，跨平台）、`screenshot`（缩放和 JPEG 编码，跨平台）、`windows`（GDI 截图、`SendInput` 键鼠、`ShellExecuteW` 打开、前台程序名、点到别的程序的窗口上拒绝、打开就会运行的文件不开）；`ToolSet` 把几个后端合成一个。端到端测试的依赖只在非 Windows 上编。`cargo clippy --target x86_64-pc-windows-gnu` 和 `cargo test --no-run`（MinGW 链接）都过；Linux 上单元测试过。

- **`apps/windows` 托盘应用**（工作区成员 `thinktin-windows`，egui 0.31 + tray-icon 0.21，说明见 [docs/windows.md](../windows.md)）：登录页（验证码、60 秒重发）、手机控制（状态、开始 / 停止、正在执行的工具、被顶掉 / 被拒的提示）、手机（配对二维码带倒计时、解除配对）、授权列表、设置（开机自启写注册表 Run 键、退出登录）；托盘图标颜色随状态，菜单打开 / 开始停止 / 退出，关窗口收进托盘；`state.bin` 经 DPAPI 存会话、配对私钥、开关；`--background` 启动不显示窗口，按上次开关恢复；中英文按系统语言，加载系统中文字体。Linux 上 clippy 和单元测试过；`x86_64-pc-windows-gnu` 上 clippy 过、release 构建出了 `thinktin.exe`（MinGW 链接）。
- **CI、发版、文档**：`windows.yml`（windows-latest 上 fmt、clippy、测试、未签名 exe）、`windows-release.yml`（`windows-v*` 标签：构建、有证书就签名、Inno Setup 安装包 `apps/windows/installer/thinktin.iss`、GitHub Release）；`docs/windows.md`；README、架构方案 8.6 和待决问题、relay / pairing / desktop 文档里的“只有 macOS”；WBS 14.10–14.14；许可证检查加 Windows 程序（只算 Windows 平台的依赖，允许 Ubuntu 字体许可证）。

进行中：
- 无。等用户安排：`windows.yml` 还没在 GitHub 上跑过（见“坑和决定”）。

下一步：
1. 让 `windows.yml` 跑一次（开 PR 或合进 main），修 MSVC 上的问题。
2. 要人做的：在 Windows 真机上跑一遍（托盘、登录、配对、截图、键鼠、开机自启）；准备代码签名证书（docs/windows.md 第 6 节）；定接口和中继的正式域名。
3. 以后：对话和计划的主窗口；应用内检查更新；单实例互斥量；截图排除自己的窗口；配对密钥放 TPM。

坑和决定：
- `windows.yml` 只在本分支上，GitHub 不让手动触发不在默认分支上的工作流（API 返回 404），CI 也只在 main / backend-core 的推送和 PR 上跑，所以 MSVC 目标还没真实编过。按规矩没擅自开 PR；要跑的话开个草稿 PR 就行。这里用 MinGW 交叉编译做过 clippy 和 release 构建，出了 `thinktin.exe`。
- 云端会话是 Linux，没有 Windows 机器。`apt-get update` 之后能装 `gcc-mingw-w64-x86-64`，加上 `rustup target add x86_64-pc-windows-gnu`，就能在这里对着 Windows 目标 `cargo clippy` 和 `cargo test --no-run`（环境变量 `CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc`、`AR_…=x86_64-w64-mingw32-ar`、`CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc`；aws-lc-sys 这样交叉也能编）。跑不了：真机上的截图、键鼠、托盘要人试，MSVC 目标的编译靠 GitHub Actions 的 windows-latest。
- Windows 上“应用”的写法是程序名（`chrome.exe`），对应 macOS 的 bundle id；手机授权页照样填这个字符串。`computer_key` 里的 `cmd` 在 Windows 上是 Win 键，不是 Ctrl。
- 电脑端用 Rust 直接写界面（不像 macOS 那样经 UniFFI 给 Swift），`desktop` 库原样复用。

# claude/windows-version-dev-vafc9z

目标：Windows 电脑端（架构方案 8.6 里“暂不做”的那一项）。和 macOS 端对齐：托盘常驻的电脑端工具服务（Rust 的 `desktop`，经设备中继让用户的 agent 用这台电脑）、登录、手机配对二维码、能力令牌和高危审批把关、开机自启、安装包分发。对话和计划的主窗口（macOS 上复用 ThinktinUI）不在这一期。

认领：Windows 会话（session_012PgAxFAJsLo683tK5xbEqo）在做，2026-10-27 起。后端 `DevicePlatform` 加 `windows`、`desktop` 库跨平台这两处会碰 `crates/**`，别的分支如果也要改这些地方，请在这里记一句。

已完成：
- 分支与进度文件（本文件）。
- **后端认 Windows 是电脑**：`DevicePlatform::Windows` + `is_computer()`（中继、设备消息方向、网关登录唤醒等电脑的运行、执行器的提示文案），迁移 `0023_windows_devices.sql` 放宽 `devices.platform` 的约束；client-core 的 `capability_allows_path` / `capability_message` 认 Windows 路径（盘符、UNC、两种分隔符、不分大小写、`\\?\` 前缀，`DirPath`）；iOS / 安卓授权页的目录校验也收 `C:\…`（没法在这里跑 Swift / Gradle，改动只有几行）。`cargo test` 过（store、relay、gateway、client-core、orchestrator、desktop）。
- **`desktop` 库跨平台**：命令在 Windows 上走 PowerShell（不开控制台、UTF-8 输出、带回原生退出码），删除进回收站（`SHFileOperationW`），`policy::resolve` 去掉 `\\?\`，`computer_open` 按 `Path::is_absolute` 分路径和应用；新模块 `keys`（按键写法解析，跨平台）、`screenshot`（缩放和 JPEG 编码，跨平台）、`windows`（GDI 截图、`SendInput` 键鼠、`ShellExecuteW` 打开、前台程序名、点到别的程序的窗口上拒绝、打开就会运行的文件不开）；`ToolSet` 把几个后端合成一个。端到端测试的依赖只在非 Windows 上编。`cargo clippy --target x86_64-pc-windows-gnu` 和 `cargo test --no-run`（MinGW 链接）都过；Linux 上单元测试过。

进行中：
- `apps/windows`：Rust 的托盘应用（登录、状态、配对二维码、授权列表、开机自启、DPAPI 存会话和配对密钥）。

下一步：
3. CI：`windows.yml` 在 windows-latest 上编译、测试；发版工作流出安装包。
4. 文档：`docs/windows.md`、README、架构方案 8.6 和待决问题、WBS 14.10–14.14、许可证检查加 Windows 程序。

坑和决定：
- 云端会话是 Linux，没有 Windows 机器。`apt-get update` 之后能装 `gcc-mingw-w64-x86-64`，加上 `rustup target add x86_64-pc-windows-gnu`，就能在这里对着 Windows 目标 `cargo clippy` 和 `cargo test --no-run`（环境变量 `CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc`、`AR_…=x86_64-w64-mingw32-ar`、`CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc`；aws-lc-sys 这样交叉也能编）。跑不了：真机上的截图、键鼠、托盘要人试，MSVC 目标的编译靠 GitHub Actions 的 windows-latest。
- Windows 上“应用”的写法是程序名（`chrome.exe`），对应 macOS 的 bundle id；手机授权页照样填这个字符串。`computer_key` 里的 `cmd` 在 Windows 上是 Win 键，不是 Ctrl。
- 电脑端用 Rust 直接写界面（不像 macOS 那样经 UniFFI 给 Swift），`desktop` 库原样复用。

# claude/windows-version-dev-vafc9z

目标：Windows 电脑端（架构方案 8.6 里“暂不做”的那一项）。和 macOS 端对齐：托盘常驻的电脑端工具服务（Rust 的 `desktop`，经设备中继让用户的 agent 用这台电脑）、登录、手机配对二维码、能力令牌和高危审批把关、开机自启、安装包分发。对话和计划的主窗口（macOS 上复用 ThinktinUI）不在这一期。

认领：Windows 会话（session_012PgAxFAJsLo683tK5xbEqo）在做，2026-10-27 起。后端 `DevicePlatform` 加 `windows`、`desktop` 库跨平台这两处会碰 `crates/**`，别的分支如果也要改这些地方，请在这里记一句。

已完成：
- 分支与进度文件（本文件）。

进行中：
- 后端：`DevicePlatform::Windows`，“电脑”的判断从“是 macOS”改成 `is_computer()`（中继、设备消息、网关登录唤醒、执行器）；迁移放宽 `devices.platform` 的约束；client-core 的 `capability_allows_path` 认 Windows 路径。

下一步：
1. `desktop` 库跨平台：命令用 PowerShell、删除进回收站、路径解析去掉 `\\?\`、`computer_open` 按绝对路径判断；Windows 的系统工具（截图、键鼠、打开、前台应用）用 Win32 直接在 Rust 里实现（不需要 UniFFI）。
2. `apps/windows`：Rust 的托盘应用（登录、状态、配对二维码、授权列表、开机自启、DPAPI 存会话和配对密钥）。
3. CI：`windows.yml` 在 windows-latest 上编译、测试；发版工作流出安装包。
4. 文档：`docs/windows.md`、README、架构方案 8.6 和待决问题、WBS 14.10–14.14、许可证检查加 Windows 程序。

坑和决定：
- 云端会话是 Linux，没有 Windows 机器，也装不上 MinGW 交叉编译器（apt 里没有）。Rust 代码在 Linux 上 `cargo check` 跨平台的部分，Windows 专有的部分靠 GitHub Actions 的 windows-latest 编译和测试；真机上的截图、键鼠要人试。
- 电脑端用 Rust 直接写界面（不像 macOS 那样经 UniFFI 给 Swift），`desktop` 库原样复用。

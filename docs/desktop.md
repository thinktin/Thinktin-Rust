# 电脑工具（WBS 14.2）

agent 用“我的电脑”的工具，经 [设备中继](relay.md) 转到用户自己的 Mac 或 Windows 电脑上执行。分三部分：

| 部分 | 位置 | 做什么 |
|---|---|---|
| 工具清单 | `crates/proto/src/computer.rs` | 平台交给 agent 的 `computer_*` 工具：名字、说明、参数、风险等级、平台等多久 |
| 平台侧 | `crates/orchestrator/src/executor.rs`、`computer.rs` | 有电脑的用户的 agent 才拿到电脑工具；调用经中继转给用户自己的电脑；电脑不在线时转入等电脑上线 |
| 电脑侧 | `crates/desktop` | 连中继、按手机给的权限把关、执行、记本地审计日志；Windows 的系统工具在 `windows.rs`（[Windows 电脑端](windows.md)） |

## 1. 工具和风险等级

| 工具 | 做什么 | 风险 | 电脑上要什么 |
|---|---|---|---|
| `computer_list_dir` | 列目录 | 只读 | 能力令牌覆盖这个目录 |
| `computer_read_file` | 读文件（文本、图片，大文件分段） | 只读 | 能力令牌覆盖这个目录 |
| `computer_screenshot` | 截屏 | 只读 | 有任意一张有效的能力令牌 |
| `computer_write_file` | 写、追加文本文件 | 普通 | 能力令牌覆盖这个目录 |
| `computer_open` | 打开网页、应用（bundle id）、文件 | 普通 | 网页：任意有效令牌；应用：令牌覆盖这个应用；文件：令牌覆盖目录 |
| `computer_click`、`computer_type`、`computer_key` | 键鼠 | 普通 | 能力令牌覆盖前台应用 |
| `computer_delete` | 挪进废纸篓 | 高危 | 每次都要手机签名批准 |
| `computer_run` | 执行 shell 命令 | 高危 | 每次都要手机签名批准 |

高危工具要 agent 给出 `reason`，显示在手机的审批界面上。只读和普通操作平台最多等 60 秒，高危操作最多等 15 分钟（等用户在手机上批准）。

## 2. 平台侧

- **只给有电脑的用户**：执行器在每次尝试开始时看用户有没有登录着的电脑（macOS、Windows 设备，`DevicePlatform::is_computer`）；没有就不把电脑工具交给 agent。
  运行授权的默认范围包含电脑工具（`[api] default_platform_tools`）。
- **不卡执行器**：电脑工具的调用放到单独的任务里等结果，执行器照常续租、处理别的事件、发现用户取消。
- **电脑不在线**：告诉 agent，停下这一轮，运行转入“等待电脑上线”（7.11），通知用户；电脑连上中继时唤醒，
  带着续跑说明接着跑。超过计划的 `wait_timeout_secs`（默认 24 小时）按计划策略结束。
- 其他失败（电脑没有这个工具、超时、转出去以后断线）作为工具错误交给 agent。电脑工具不在“副作用只执行一次”（7.13）
  的名单里：agent 重试同样的调用，电脑会再做一次（高危操作反正每次都要用户批准）。
- **审批提醒**：电脑经中继发给手机的审批请求，后台每 2 秒看一次，写进收件箱（`computer_approval`）、推送到用户的手机
  （高优先级，iOS 的 category 是 `COMPUTER_APPROVAL`，Android 走审批的通知渠道）。通知上没有按钮：批准和拒绝都要
  打开 App 用私钥签名。正文是电脑写的说明的第一行（标“AI 生成”），推送跟着请求一起过期。每条只提醒一次；
  手机已经取走的、已经过期的不提醒。App 收到推送后拉 `GET /v1/devices/current/messages` 取请求。

## 3. 电脑侧（`desktop` 库）

macOS App 的后台进程里跑一个 `Desktop`：

- **连接**：主动连中继（`wss://…/v1/connect`，带这台电脑的访问令牌），断了按退避重连；每 10 分钟在连接里换一次访问令牌；
  被中继以 4001 关掉时刷新令牌重连；账号被冻结（4003 / 403）、这台电脑在别处又连了一次（4009）时停下，交给 App 提示用户。
- **报工具**：连上时把现在能用的工具报给平台（随系统权限变化：没给屏幕录制权限就没有截图）。平台不会转电脑没报的工具。
- **普通操作**：要一张配对的手机签发、验过签、没过期、没吊销的能力令牌覆盖：文件按目录（先解开符号链接，
  链接指到授权目录外面就按外面算），键鼠按前台应用的 bundle id。令牌和吊销经中继从手机来，验签后存在本地。
- **高危操作**：给配对的手机发审批请求（工具、参数、说明、期限），等用户用私钥签名批准；本地用配对时记下的手机公钥验签，
  通过才做。拒绝、超时、签名不对都不做，告诉 agent 不要换别的办法。
- **审计日志**：每个调用一行 JSON（`audit.jsonl`）：时间、调用、发起的运行、工具、参数的摘要（和审批签的是同一个摘要）、
  权限结论（允许 / 拒绝 / 批准 / 不批准）、执行结果。不记参数原文，也不记读到、写进的内容。
- **本地状态**（`desktop-state.json`）：配对的手机（设备 id、公钥）、能力令牌、吊销过的令牌 id。换了手机，之前的令牌作废。
- **配对**（14.8 的 Rust 部分，`pairing`）：App 的“配对手机”调 `start_pairing(电脑的密钥, 有效期)`，拿到二维码的内容
  （`thinktin-pair:v1?…`，32 字节随机数，最长 10 分钟）；手机扫码后签名回复（`pair_response`）经中继到电脑，电脑对上
  正在显示的邀请（随机数）、用 client-core 验手机的签名，先记下手机，再用电脑的密钥签确认（`pair_confirm`）发回。
  一次只有一个邀请，重新开始会作废上一个；回复验不过时这个二维码作废，要重新出。App 跟着 `watch_pairing()` 显示
  等待、配好、失败（`PairingStatus`），关掉二维码调 `cancel_pairing()`。电脑的密钥由 App 放在钥匙串 / Secure Enclave
  里（实现 `PairingKey`），`SoftwareKey` 给测试和开发用。

工具本身由 `ToolBackend` 实现：看目录、读写文件、删除（挪进 `~/.Trash`，Windows 上进回收站）、执行命令（`/bin/sh -c`，
Windows 上是 PowerShell，最多两分钟，输出各留 64 KiB）用 Rust 实现（`files::FileTools`）；截图（ScreenCaptureKit）、键鼠、打开应用
要用 macOS 的系统接口，由 App 实现（14.3、14.4），和 `FileTools` 组合起来交给 `Desktop`；Windows 上这几个用 Win32 在 `windows.rs` 里实现，
用 `ToolSet` 和 `FileTools` 合起来。访问令牌由 App 用 client-core 管（`TokenSource`）。

## 4. macOS App 用的接口（UniFFI）

`desktop/src/ffi.rs`：App 的后台进程建一个 `DesktopService(settings, tokens, native, observer)`，它在自己的 tokio 运行时里跑
`Desktop`。`start()` 连中继（一直连着，断了重连），`stop()` 断开；`start_pairing(signer, ttl)` 出配对二维码，
`cancel_pairing()`、`paired_phone()`、`unpair()`、`grants()` 给菜单栏和配对界面。App 实现四个接口：

| 接口 | 做什么 |
|---|---|
| `DesktopTokens` | 这台电脑的访问令牌（App 用 client-core 的 `ThinktinClient` 管会话） |
| `NativeTools` | 截图、键鼠、打开应用（14.3、14.4）；文件和命令由 Rust 的 `FileTools` 做，App 报的同名工具不会覆盖它们 |
| `PairingSigner` | 电脑的配对密钥（钥匙串 / Secure Enclave） |
| `DesktopObserver` | 连接状态、配对进度、停下的原因（`Requested`、`Refused`、`Replaced`）、正在执行的工具（`on_activity`，菜单栏的“正在被控制”）；回调在后台线程上 |

打包：`desktop` 编成静态库（里面也有 client-core），绑定按库生成两份（`ThinktinCore.swift`、`ThinktinDesktop.swift`）。
desktop 的绑定直接用 client-core 的类型，所以两份放进同一个 Swift 模块；C 头文件放在一个模块映射里的两个模块
（`ThinktinCoreFFI`、`ThinktinDesktopFFI`），都链接 `libdesktop`。iOS App 照旧只用 client-core。
`tools/desktop/swift-smoke.sh` 在 Linux 上按这个样子编出来，用 Swift 实现这几个接口跑一遍（开始、停止、状态回调、错误两个方向）。

## 5. 还没做的

- ~~macOS App（14.5–14.9）~~、~~截图、键鼠、打开应用（14.3、14.4）~~：代码已写（菜单栏、登录项、权限引导、钥匙串里的
  配对密钥和二维码、ScreenCaptureKit / CGEvent / NSWorkspace 的系统工具、Developer ID + 公证 + Sparkle 的发版），见
  [macOS App](macos.md)；还没在 Mac 上跑过，第 8 节是剩下的。
- ~~手机的配对和审批界面（12.9、13.9）~~：已做（iOS、安卓）：扫码配对、收到 `computer_approval` 推送或进前台时拉
  `GET /v1/devices/current/messages`，显示请求、签批准或拒绝（签的是显示的说明和参数的摘要），发回电脑；签发、吊销能力令牌。
- ~~电脑发的说明是英文的~~：手机按自己的界面语言说执行命令、删除（照签名覆盖的参数，理由照原话），别的工具还用电脑的英文说明。


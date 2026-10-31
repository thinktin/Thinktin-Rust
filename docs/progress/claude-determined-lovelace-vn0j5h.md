# claude/determined-lovelace-vn0j5h

## ⚠️ 紧急交接（2026-10-29 16:00 UTC，本会话 session_016LgPcdynywrhrjCq8VVFLt 周额度快用完）

**接手的先读这一节。** 下面原来的内容（10-25 起的现状、已完成、坑）照样有效。

### 0. 现状一句话

- 代码都推送了，工作区干净。本节下面的提交都在 `origin/claude/determined-lovelace-vn0j5h` 上（仓库 github.com/thinktin/Thinktin-Rust，
  10-29 从个人账号移到组织，路径变了，代码没变）。
- `cargo test --workspace` 全过（616 个，要 Postgres：`THINKTIN_REQUIRE_DB=1`），`cargo clippy --workspace --all-targets` 干净。
  已知偶发：`crates/relay/tests/relay.rs` 的 `heartbeats_drop_revoked_frozen_and_silent_computers`，重跑就过。
- 手上三件事都在**设计阶段**，一行实现代码都还没写：
  1. 出口代理，也就是“受管控的上网通道”（WBS 2.7）；
  2. 浏览器；
  3. 项目与跨用户协作（8.13–8.19）。
- 用户最新的要求（10-29）：“先看受管控的上网通道怎么设计，然后再确定浏览器怎么设计”。所以顺序是 **出口代理 → 浏览器 → 项目**。
- **合并**：用户 10-29 让把现在的改动合进 main。已开 [PR #18](https://github.com/thinktin/Thinktin-Rust/pull/18)（本分支 → main，
  已先合入 main 的 #16，本机全部检查都过），CI 在跑：rust、android、ThinktinKit on Linux、iOS 模拟器（要 20 分钟以上）。
  - CI 全绿就 **squash 合并**，标题后面加 “(#18)”，和 #14、#16 一样。红了就修，修好再合。
  - 如果本会话额度先用完，下一个 agent 按上面接着做。
  - 合并以后：
    1. 删掉 GitHub 上的 `autosave/claude-determined-lovelace-vn0j5h`（CLAUDE.md 的规则）。
    2. 后续工作从最新的 main 重新开始，分支名不变：`git fetch origin main && git checkout -B claude/determined-lovelace-vn0j5h origin/main`。
       分支上只有已经合并的历史时，可以用 force-with-lease 推送。
    3. 把本文件这一条改成“已合并”。

### 1. 这一轮做完的（10-29，都已推送）

| 提交 | 内容 |
|---|---|
| `1d858a4` | agent 交流第三轮评审修复：紧急消息排队时打断记在排第一的那条上；领取时再查刚提交的紧急消息；产出物范围改成“自己的加上下面各个问题（含嵌套）的回答方的”、`= ANY` 查询、列表最多 500；`artifact_list` 带 `artifact_id`，读、取可按它挑同名的；交还结果先记 `handed_at` 再发；各取消路径先按 id 顺序锁运行 |
| `ca1764c` | 上面的文档 |
| `182dcb2` | client-core：运行列表、缓存里读不了的（新来源、新状态）跳过，不再整页失败（上线前必须做的那条） |
| `3de0400` | webhook 评审修复（16 条，每条 2 个反驳者核对）：洪水在查库前挡掉、加锁顺序、计划每日 token 上限、随机边界标记、`url_verification`、排着的事件运行不吞定时触发、有 webhook 的计划不能加步骤、删实例连 webhook 删、静音计划不开实时活动 |
| `50e1b0f` | 上面的文档（`docs/event-triggers.md`） |
| `a035fec` | **浏览器调研** [`docs/browser.md`](../browser.md)：自己做为主，AgentBay 以后当“大陆浏览器”；价格、工作量、风险、来源 |
| `2c0897a` | 设计草稿存档 `docs/progress/drafts/`（见第 3 节） |

### 2. 下一步（按顺序）

**① 出口代理设计（WBS 2.7）→ 写 `docs/egress.md`**

- 已有的调研在 [`drafts/egress-survey.md`](drafts/egress-survey.md)。一份是我们的现状（file:line），一份是业界方案（带链接）。
- 第三份调研“各 agent 和常用工具要连哪些地方、走不走代理”没做完。workflow 脚本在 `drafts/workflows/egress-design.js`，里面有现成的
  prompt：3 份调研、3 个角度的设计、2 个评委、合成、查漏。
  - 跨会话不能 resume，要重跑。可以把已有两份调研的结果直接贴进 prompt，只跑缺的那份调研和后面几步。
- 已经看出来的方向（已经告诉用户）：
  - 沙箱照旧全部拒绝出网，只放行模型网关和代理所在的服务机 IP（ACS allowOut）。
  - 服务机上加一个显式的 HTTP CONNECT 代理，沙箱用 `HTTP(S)_PROXY` 连它。不走代理的一律不通（fail closed）。
  - 按 Pod IP 认沙箱，和 llm-gw 一样，ACS 不 SNAT。可以再加每个沙箱的代理口令。
  - 档位：只连模型 / 常用开发网站白名单（参考 Codex 71 个、Claude 约 215 个）/ 用户加的网站 / 全部开放。
  - 必须做：
    - 挡住所有非公网地址，含 100.64/10（阿里云元数据 100.100.100.200）、169.254/16、RFC1918、IPv6 映射；
    - 解析一次、钉住 IP 再连；
    - 只开 80/443，挡住 25/465/587；
    - 沙箱里不给 DNS；
    - 每条连接记元数据、不记内容，保存 ≥ 6 个月（网络安全法修订后第 23 条，2026-01-01 施行）。
  - 选型：
    - Stripe Smokescreen（Go，MIT，有解析钉住、ACL、限速、按域名 MITM 加请求头）；
    - 或者自己用 Rust 写一个小的，复用 `crates/llm-gw/src/ssrf.rs`，要 MITM 用 hudsucker。
    - 阿里云托管的方案太贵：ACS 增强出口管理默认规格约 ¥1,550/月加 NAT；云防火墙 NAT 边界约 ¥1,825/月加 NAT。
  - TLS 只对用户为保险箱填密码打开的域名做中间人（`docs/vault.md` 的请求头注入），别的一律不解密。
  - Node 要设 `NODE_USE_ENV_PROXY=1`。curl 只认小写的 `http_proxy`。Yarn Berry 要 `YARN_HTTPS_PROXY`。git 只能走 https。Chromium 用
    `--proxy-server` 加 `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`。
  - 法律风险（要问律师）：东京的浏览器让国内用户实时看、操作被屏蔽的外网，像跨境访问通道。只让 agent 自己访问开发资源的风险小。
- 写完以后，用简单中文给用户列要拍板的事，每条附建议的默认值：
  - 默认档位（建议：只连模型加常用开发网站）；
  - 全部开放要不要用户自己打开；
  - 日志保存多久；
  - 流量上限。

**② 浏览器设计**：在出口代理上面接着做，起点是 [`docs/browser.md`](../browser.md) 第 5 节，原始调研在 `drafts/browser-research.json`。

- 要点：
  - Chromium 装进沙箱的浏览器版镜像，连依赖约 0.65–0.8 GB；
  - agent-shim 起 Chromium，只听 127.0.0.1、经代理出网；
  - 五个 agent 都接同一个 Playwright MCP。OpenClaw、Pi 要写进它们自己的配置文件；
  - **Hermes 一看到 `/usr/bin/chromium` 就会自己挂出浏览器工具**，要处理；
  - 实时看、接管走 CDP 截帧经网关推到 App；
  - 规格先在东京 ACS 实测再定。

**③ 项目与跨用户协作设计 → 写 `docs/projects-impl.md`**

- 三份设计在 `drafts/projects-design-{A,B,C}.md`。两个评委（安全、可实现性）的打分和 must_fix 在 `drafts/projects-judgments.json`：
  **A 16 分、B 13.5、C 10**（两个评委合计）。产品评委、合成、查漏都没跑。
- 建议以 A 为底，因为数据库里强制项目边界：`thinktin_member` 角色、`thinktin_definer` 持有 definer 函数、
  `scope_id = coalesce(project_id, user_id)` 复合外键、`events_fill` 按项目序号、每个项目一个 HOME、私人工作目录挪到 `private/`。
- 从 B 嫁接：
  - `ProjectActor` 能力令牌：没有核对就编译不过；
  - `runs_project_guard`：只有后台角色能写项目运行；
  - `ProjectTx` 只读、是独立类型；
  - 事件 payload 按种类裁剪后再给成员看；
  - 注销账号时别人的子运行 SET NULL，不级联删除。
- 必须修 A 的这些问题（安全评委指出）：
  - 注销账号级联删掉别的用户的子运行；
  - inbox 的策略让邀请通知对被邀请人不可见；
  - 业务角色能自己插项目运行和子运行；
  - `project_feeds` 不该给 app 写权限；
  - 成员能看到原始的工具调用输出；
  - 删项目是一个大事务，可能超时。
- 硬约束：已装的 App 还在调 `/v1/teams*` 和 Team FFI，要保留兼容（这个容器不能编 iOS / 安卓界面）。
- 调研原文在 `drafts/projects-survey.json`。脚本在 `drafts/workflows/projects-design.js`。
- 设计定了再分阶段实现，第一阶段要小、要安全，每阶段都要评审。

### 3. 草稿目录 `docs/progress/drafts/`（都没评审，别当定稿）

| 文件 | 是什么 |
|---|---|
| `egress-survey.md` | 出口代理调研两份：我们的现状、业界方案和价格、法律 |
| `browser-research.json` | 浏览器调研全部结果：4 份调研、3 个方案的成本和工作量、63 条事实核对 |
| `projects-survey.json` | 项目调研：teams / rls / visibility / keys / sessions / money 六份地图 |
| `projects-design-A.md` / `-B.md` / `-C.md` | 项目的三份实现设计：A 数据库强制边界，B 跟着 agent 主人、显式检查，C 项目自己持有内容和密钥 |
| `projects-judgments.json` | 安全、可实现性两个评委的打分、优点、缺点、嫁接、必须修 |
| `workflows/*.js` | 这两轮设计用的 workflow 脚本，可以改了重跑 |

设计定稿写进正式文档后，把对应的草稿删掉。

### 4. 用户那边要拍板或要做的事

- **浏览器**：默认开还是关（建议关）；国内网站显示“IP 属地 日本”怎么提示；每人每天的浏览分钟上限；开放浏览之前问律师（跨境访问）。
- **出口代理**：见第 2 节①。
- **以前就有的**：充值、域名、短信签名、法务复核（`docs/licenses.md` 第 6 节）；可以删掉 GitHub 上的 autosave 分支。
- **App 那边要做**（12.x / 13.x，这个容器做不了）：
  - 计划策略模型带上 `notify_success`；
  - 加 webhook 时预授权里有执行命令、联网、其他或全部的要提示；
  - `RunSource.ask` 显示成“队友提问”、带 AI 标识，不认识的来源别当成用户发的。

### 5. 规矩（用户定的，一定要遵守）

- 用户不是技术人员：**用简单中文说话**，少用术语，非用不可就用几个字解释。
- 不让用户在聊天里贴密钥、口令；不打印、不提交密钥。密钥只放云端环境变量（不放启动脚本、不放 Network secrets）；生成的秘密
  只放 `target/`。
- 建要花钱的云资源前，先列出费用、等用户同意（免费的 VPC、交换机、安全组可以直接建）。
- 自动模式拒绝的操作不要想办法绕过，比如释放 EIP、装外部 git 代码、新会话里建云资源：告诉用户，让他在控制台点。
- 不要再催用户换阿里云 key、作废 Codemagic token。
- 提交信息不写模型名，只在结尾带那两行 trailer。不建 PR，除非用户要；用户说“合并”才合并。
- 不在 `main` 上改；小步提交、马上推送；每个提交只改一条线（后端 / iOS / 安卓）；进度记在本文件。
- **额度**：今天连撞了 3 次 5 小时上限，之后又快撞周额度。
  - 不要同时跑几个大 workflow。
  - 每轮跑完马上把中间结果存进 `docs/progress/drafts/` 并推送：workflow 的结果只在本会话的临时目录里，换了会话就没了。
  - `resumeFromRunId` 只能在同一个会话里用。


> **接手先读 [交接文档](../handoff.md)**（2026-10-28）：现在在做阿里云部署（国内站账号、东京、ACS 容器版沙箱实测），下一步和规矩都在那里。
> 10-28 补：容器版脚本写好了（`deploy/aliyun/acs.py`、`sandbox.py --acs`）；云端会话连不上集群的 API Server，kubectl 要在集群 VPC 里跑（交接文档第 3、4 节）。

目标：2026-10-25 用户让“看上一个 agent 的进度，把工作梳理清楚，继续开干，不用停；额度恢复就自动开干”。三条线（后端 `backend-core`、iOS `ios-app`、安卓 `android-app`）10-23 起按用户要求暂停，原来的三个会话已经找不到了，由本会话（session_01JYVuTJTo78Zrenhct8Bkw5）接着做。

## 分支

- 本分支是**集成分支**：从 `ios-app`（`c0d6c54`）切出，合了 `android-app`（`43ce7c7`），两边都已经合到 `backend-core` 的 `67f9e7a`。合并只在 `docs/gen_wbs.py` 上冲突（11.7 / 11.8 取 iOS 的，13.x 取安卓的），`wbs.md` / `wbs.csv` 重新生成：162 个包、775 人日。
- 会话分配的分支就是这个，按规则不直接推 `backend-core` / `ios-app` / `android-app`。**每个提交只改一条线**（`apps/android/**` + 安卓进度，或 `apps/apple/**` + `tools/apple/**` + iOS 进度，或 `crates/**` 等后端），以后可以逐个 cherry-pick 回各自的分支；用户同意的话也可以直接把各分支快进到这里对应的提交，或者整个分支一起合。
- CI 只在 `main` / `backend-core` 的推送和 PR 上跑，本分支没有 PR 就没有 CI，所以推送前在本机验证：Rust（cargo test，集成测试要 Postgres）、Swift 6.2（Linux，`/opt/swift`）跑 ThinktinKit 和 uicheck、Android SDK（`/opt/android-sdk`）跑 Gradle 的 test / lint / assembleDebug。macOS 上真实 SwiftUI 的编译只能等 iOS CI（PR #8）。
- 自动续跑：每小时一次的定时任务叫醒本会话（见“坑和决定”），撞上用量限额后恢复时自己接着做。

## 现状（2026-10-25 梳理）

### 后端（`backend-core`，进度在 `docs/progress.md`）

P1 后端核心（M1–M9）和 P2 里能在代码层面完成的包都做完了，CI 绿，PR #5 等人审、合并。剩下的：

- **代码上还能做的**：11.9 评审修复（`3d53748`、`ef80477`）的最后一轮复核；安卓已经不读 `PLAN_ONLY_BASES`，可以去掉（先确认 iOS 和测试都不用）。
- **等部署 / 集群（2.2、2.3、2.5、2.7）**：Cube 真实集群联调（6.2、6.6、7.12 整机快照、7.15 预发演练）、出口代理（保险箱请求头注入、沙箱出网白名单）、17.5 正式压测数字、6.8 envd 和模板注册、2.9 集群与第一次发布。
- **等人拍板**：5.6 运行附件（等 1.1）；16.5 法务复核（`docs/licenses.md` 第 6 节）；短信、KMS 服务商按默认接了阿里云，待确认；15.5 每个 agent 的负责人和季度演练；`mobile.yml` 合到 main 后实跑一次。

### iOS（`ios-app`，进度在 `docs/progress/ios-app.md`，PR #8 草稿）

已完成 12.1、12.2、12.3、12.4（已审查）、12.5、12.6、12.12、12.16，和 backend-core `67f9e7a` 对齐。Linux 上 846 个测试，uicheck 83 个。

下一步（按原计划）：
1. 对抗式审查 12.5、12.6、12.12（合并前没审）。
2. 合并后留下的小项（ComposerBar 共用、`InstanceEventKind.instanceState`、`AppRoute.artifact`、BiometricGate、`MockClient.makeTrigger` 的下次触发时间、用词统一、设置里的跳转等，见 iOS 进度文件“下一步 2”）。
3. 第三轮：12.7 团队与流水线、12.8 推送与收件箱、12.15 审批中心、12.17 引导与空状态、12.18 产出物。
4. 之后：12.13、12.10、12.20、12.21、12.19，12.11 最后；12.9 随 macOS（P3）。
5. uicheck 的盲区（`#if os(iOS)` 分支查不到）。

### 安卓（`android-app`，进度在 `docs/progress/android-app.md`，PR #7 草稿）

已完成 13.1、13.2、13.3、13.4、13.16，破坏性改动适配，和 backend-core `67f9e7a` 对齐。437 个 debug 测试 + 163 个 release 变体，lint 0 错误。

下一步（按原计划）：
1. 13.5 对话与运行过程：已有大量代码（`ui/chat/` 下 7 个文件和测试），停在部分改动的快照上（`ba78a8d`）。先对照 WBS 13.5 和设计规范第 8 节补齐，再评审、修复、验证。
2. 13.6 计划 → 13.8 推送与收件箱 → 13.13 设置 → 13.7 团队与流水线 → 13.11 / 13.12，之后 P2 的 13.10、13.14。

## 本会话的顺序

先搭环境（Swift 6.2、Android SDK、client-core 本机库），然后两个客户端交替推进，每做完一个包就提交推送、更新本文件：

1. 安卓 13.5 补齐 → 验证 → 推送。
2. iOS 审查 12.5 / 12.6 / 12.12 → 修 → 验证 → 推送。
3. 安卓 13.6；iOS 12.15、12.8；安卓 13.8；iOS 12.7、12.18、12.17；安卓 13.13、13.7……
4. 后端的两个小项穿插着做。

已完成：
- 集成分支（`6375b05`）；本文件（`276f2c5`）。
- 后端：去掉 `PLAN_ONLY_BASES`，`plan_only_base` 逐家查（`854c017`）。
- iOS 审查 12.5 / 12.6 / 12.12，修三处（`85cd7e3`，详见 iOS 进度文件）：举报说明按标量数、agent 待办清单能举报、运行详情停止冲突后刷新。
- 安卓 13.5 收尾（`f93ad4c`）：代码已齐，修运行页深链定位少算一行。
- 安卓 13.6 计划（`21fdc49` 及之前的 `schedule/`）：列表、详情、新建 / 编辑、触发规则面板，本地的 cron / RRULE 预测。全量 test / lint / 打包通过。
- iOS 12.15 审批中心与审批详情（`0ea8a8e`）。
- iOS 12.8 推送与收件箱（`691e1ab`）：收件箱和单条通知页、点开推送标已读、通知上的“拒绝”、APNs 令牌上报、角标和退出登录清通知、
  `AppDelegate`；uicheck 加了 UserNotifications 的桩，App 的推送代码在 Linux 上也做类型检查。866 个测试。

- 安卓 13.8 推送与收件箱：收件箱页面、通知渠道（`tt_approval` / `tt_results`）、推送点开跳转和标已读、令牌上报流程；推送 SDK 没接（要人定，见下）。
  全量 test（app 292）/ lint / 打包通过。

- iOS 12.18 产出物（`c4e0c1a`）：产出物库、产出物详情（预览、分享时文件名带 AI 标识、删除），新路由 `.artifact(id, runID:)`。
- 安卓 13.13 设置、多语言与开源许可（`c2f3b66`）：语言（AppCompat 的应用语言）、通知、关于、开源许可页。app 测试 301 个。
- iOS 12.17 引导：五步清单、换新机检查、登录后才注册 APNs、通知权限在引导最后一步问。876 个测试。

- 安卓 13.7 团队与流水线：团队、模板、团队编辑、计划编辑页里的流水线步骤（本地 DAG 规则同服务端）。app 测试 308 个。

- iOS 12.7 团队与流水线：团队、模板、团队编辑、流水线编辑器（本地 DAG 规则同服务端），运行树补停止、等待提示和定时刷新；
  Mock 新建计划允许没有触发规则（和服务端一致）。906 个测试。

- 安卓 13.11 上架（App 里的部分）：首次启动的隐私政策页、登录页同意勾选框（默认不勾）、个人信息与权限页（清单、权限、撤回同意）。
- 安卓 13.12 官网安装包：`direct` 渠道、应用内更新（清单 → 下载 → SHA-256 / 包名 / 版本 / 签名校验 → 系统安装）、升级页接上、
  release 签名读环境变量、`scripts/update-manifest.py`。发版和上架材料见 `docs/android-release.md`。

- iOS 12.13 密码保险箱：列表、条目、新建 / 修改（重名换名、200 条上限、限定实例）、填写请求（已有同名条目先提示）；Mock 的保险箱规则和
  服务端对齐。916 个测试。安卓全量：test 691 个 / lint / 三个渠道的 debug 包 / cn、direct 的 release 包都过。

- 安卓 13.14 密码保险箱：设置里进，列表、条目、新建 / 修改、填写请求（深链、收件箱直接到请求页）；Mock 的保险箱规则和服务端对齐。

- iOS 12.21 搜索：本机缓存里搜实例、运行、收件箱，联网时加上计划和产出物；分组、片段、AI 标识。921 个测试。

- 安卓 13.10 常驻通知：对话里发起的运行（设置能关）、运行页打开的根运行，通知栏显示状态 / 步数 / 计时，事件流更新，结束撤掉。
- iOS 12.19 TestFlight：`ios-v*` 标签触发 `.github/workflows/ios-release.yml`（全目标 ThinktinCore、API key 自动签名、上传），
  说明在 `docs/ios-release.md`。密钥、App 记录要人准备，工作流还没在 macOS 上跑过。

- iOS 12.11 上架（代码部分）：隐私清单补全、CI 扫描需声明理由的 API、`docs/ios-appstore.md`；安卓关于页加了备案号一行。

- iOS 12.20 小组件与快捷指令：Widget Extension `ThinktinWidgets`（未读、待审批、进行中，读 App Group 里的快照）、App Intents
  （全部停止、查待审批数、下任务、暂停 / 恢复计划）、`thinktin://approvals` / `active` 深链（安卓也认 `approvals`）。932 个 Kit 测试。
  App Intents、WidgetKit 只在桩上查过，真实 SDK 等 macOS CI。控制中心的“全部停止”没做（要 iOS 18 + 共享会话）。
- 后端 11.9 复查：store 的 2 个、gateway 的 `team_adoption_is_all_or_nothing` 在本机 Postgres 上都过。剩一个很窄的三方竞态
  （恢复计划、同时改步骤、同时删实例），判断不值得为它再加锁，先记在这里。

- iOS 12.10 实时活动：Kit 的 `LiveActivityModel`（自己发的任务自动开、令牌登记、前台跟事件流、计划运行的推送开启令牌、
  退出登录全部结束）、App 的 ActivityKit 适配、扩展里的锁屏横幅和灵动岛、设置里的开关、运行页的按钮。942 个 Kit 测试。
- iOS 12.14 IM 渠道设置：列表（开关、测试消息、删除、失败原因换成怎么处理）、新建 / 修改（认出平台、签名密钥、备注、事件、换地址），
  规则和 Mock 跟服务端一致。951 个 Kit 测试。

- 安卓 13.15 IM 渠道设置：和 iOS 12.14 同一套（列表、开关、测试消息、删除、失败原因、绑定 / 修改、换地址），`:data` 的
  `ImChannelRules`，Mock 跟服务端一致。
- iOS 12.9 手机控制电脑（手机这边，P3）：配对（扫码、面容 ID 签名、验电脑确认）、电脑高危操作的签名审批、能力令牌、
  Secure Enclave 密钥；client-core 补了配对消息正文。电脑那边（14.8）还没做。

- 安卓 13.9 手机控制电脑（手机这边，P3）：和 iOS 12.9 同一套（Keystore / StrongBox 签名、二维码深链配对、签名审批、
  能力令牌），配对和授权是单独的页面（对话框里的输入框 Robolectric 测不了）。电脑那边（14.8）还没做。

- 后端 14.8（Rust 部分）：`desktop` 的配对（出二维码、验手机的回复、签确认发回），端到端测试经真的中继和数据库。
- iOS 合并后留下的小项（iOS 进度文件“下一步 2”）全部做完：`ComposerBar` 通用化、`instanceState` 事件、共用列表组件改名挪到
  `Components/`、Mock 的触发器下次时间和唤醒等额度的运行（安卓 Mock 也补了唤醒）、token 用词。963 个 Kit 测试，uicheck 107 个，
  安卓 744 个。

- 后端 14.5 / 14.6 的 Rust 部分：`desktop` 的 UniFFI 接口（`DesktopService` + App 实现的令牌、系统工具、配对密钥、观察者），
  和 client-core 打进同一个库；`tools/desktop/swift-smoke.sh` 在 Linux 上用 Swift 跑通。

- macOS App 的前两步（14.5、14.6、14.8，P3）：ThinktinKit 的 `ComputerHostModel`（对着 `ComputerHost` 协议：连接状态、
  开始 / 停止、会过期的配对二维码、配对的手机和名字、手机给的授权、停下的原因）和 `FakeComputerHost`；ThinktinUI 的
  `ComputerHostPanel`（菜单栏弹出的面板，二维码的图由 App 注入）。968 个 Kit 测试，uicheck 108 个，两种桩都过。
- iOS 也认 `thinktin-pair:`（系统相机扫电脑上的二维码打开配对，和安卓一样）。

- 部署准备（10-26 用户去准备部署环境）：`docs/deploy-checklist.md`（云资源、账号、密钥、配置、第一次上线顺序）和
  `thinktin-server gen-secrets`（`4b78911`）。
- macOS App（14.3–14.9，P3，2026-10-26）：client-core 把访问令牌交给工具服务（`1dd3578`）；`build-apple.sh` 的 macOS 切片
  换成 libdesktop、两份绑定进同一个模块（`739630e`）；`ThinktinDesktopAdapter`（`3cb48b0`）；Kit 的 `ComputerHostLifecycle`
  （跟着登录状态建服务、按设备记开关）、`KeyCombination`、`ScreenshotGeometry`（`3e13fb1`）；`ThinktinMac` target：菜单栏、
  钥匙串配对密钥、二维码、截图 / 键鼠 / 打开、权限引导、登录项（`b08cc27`）；Sparkle 自动更新、`build-apple.sh --macos`
  （`0b22795`）；发版工作流 `macos-release.yml`（Developer ID、公证、appcast）和 `docs/macos.md`。uicheck 的 AppKit 版查整个
  Mac target（新桩：ScreenCaptureKit、ServiceManagement、ApplicationServices、CoreImage、Sparkle）；CI 在 macOS 上编它、
  Linux 上跑 ThinktinDesktopAdapterTests。975 个 Kit 测试。
- “正在被控制”跟着真的工具调用走：`desktop` 报正在执行的工具（`watch_activity`、FFI 的 `on_activity`），Mac 菜单栏图标和
  状态行跟着变（`9414895`）。ThinktinDesktopAdapterTests 的假令牌改成 0.2 秒后才报错（原来“正在连接”一闪就过，测试必挂）；
  `.build-desktop/` 加进 .gitignore（350 MB 的构建目录之前会被自动保存扫进快照，推送失败）。
- 电脑审批的说明按手机的界面语言说（iOS `4872597`、安卓 `cd8ce84`）：执行命令、删除照签名覆盖的参数说，理由照原话。
- 审批的角标也数电脑发来的（iOS `f8c54ed`，快捷指令的待审批数也是；安卓随本条进度一起提交）：存着的加上服务端还没收下的新请求，只数不确认。安卓全量 test 747 个、lint 通过；Kit 981 个。
- 第一次在真 Xcode 上编（2026-10-27）：GitHub 的 macOS 机器前两次排不上（run 40391238132），10-27 00:00 那次排上了；同时接了
  Codemagic（用户的账号，仓库根目录 `codemagic.yaml` 的 `apple-check`，M2，约 6 分钟一轮，API 能发起构建、读每一步的日志）。
  修了三处 Linux 上查不出来的：`build-apple.sh` 把 `#endif` 接在生成文件最后一行的注释后面（整个 ThinktinCore 编不过）、
  `ScreenshotGeometry` 要 `import CoreGraphics` 且 CGRect 在 Apple 上不是 Hashable、隐私清单扫描在 nm 读不了静态库某个成员时
  直接崩；还有一个测试的表达式类型推断超时。之后 iOS App 在模拟器上 build + test 通过、`ThinktinMac` 编译通过。
  macOS 上的 Kit 测试还查出一个真的竞态（`34056d1`）：冻结时重查成功之前排着的“冻结”报告晚到，会把刚解冻的界面又冻上；
  报告编了号，重查确认没冻结之前发出的“冻结”报告不再处理。GitHub（run 40428238188）和 Codemagic 都全绿：Kit 1092 个测试、
  iOS App 的测试、`ThinktinMac`、隐私清单检查。
- 三条线对齐（2026-10-27，用户同意）：`backend-core`、`ios-app`、`android-app` 都快进到本分支（`34056d1`，没有强推、没有合并提交），
  四个分支内容一样。PR #5（`backend-core` → `main`）、#7、#8 跟着带上了新提交；以后合一个就行（比如 #5），另外两个可以关掉。
- 合进 main（2026-10-27，用户让按正常流程合）：PR #5 合并提交 `b38cc13`，#2、#3、#4、#7、#8 随之自动标成已合并；#6（宣传视频，
  `promo/thinktin-promo.mp4`，8 MB）用户同意后也合了（`8e57096`）。main 上手动跑 `mobile.yml`（run 40434187317）：安卓过了，Apple 挂在 `___chkstk_darwin` 找不到——rustc 默认
  按 iOS 10 编，和 Xcode 26 编的 C 依赖（目标 26.5）链不到一起。PR #9 修：`build-apple.sh` 导出 `IPHONEOS_DEPLOYMENT_TARGET=16.0`、
  `MACOSX_DEPLOYMENT_TARGET=13.0`（和 project.yml 一致），Codemagic 的 `apple-package` 打全部切片验过。PR #9 合并（`b53467d`）后
  main 上重跑 `mobile.yml`（run 40440703056）：Apple、安卓都过了。
- iOS 截图（PR #9）：`tools/apple/screenshots.sh`，Codemagic 的 `ios-screenshots`（约 20 分钟，产物是 12 张 PNG）。模拟器上
  `simctl openurl` 每次都弹系统确认框挡住页面，所以 Debug 构建认两个启动环境变量 `THINKTIN_OPEN_URL`（深链）、
  `THINKTIN_OPEN_DRAWER`（`AppConfiguration`），脚本用 `SIMCTL_CHILD_*` 传。看截图发现的两个小毛病随后改了（`9daeafe`）：
  iOS 26 的玻璃导航栏让首页上滑出去的消息从状态栏后面透出来——导航栈外面套 `solidTopScrollEdge()`（顶部用实的滚动边缘）；
  审批、收件箱这类页面导航栏标题和 `PageHeader` 大标题重复——`inlineNavigationTitle` 改成主位置的标题，同一句话的大标题
  露着时不显示，滚到导航栏下面才淡入（`PageHeader` 在滚动视图坐标系里报自己的位置）。Codemagic 截图核对过，`apple-check` 全绿
  （Kit 1092、App 15 + 108、ThinktinMac）。
- 清理（2026-10-27，用户在网页上删的，代理不让会话删分支）：已合并的 13 个旧分支和三个 `autosave/*`、`claude/autosave-handoff`；
  剩 `main`、三条线、本分支（和它的 autosave）、`claude/promo-video`（宣传片的制作源码，没进 main，留着）。

进行中：
- **agent 之间的交流 8.9–8.12（2026-10-28 晚开工，本会话 session_016LgPcdynywrhrjCq8VVFLt）**：用户说“不急的几项开干”。
  顺序 8.9 认识队友与查进度 → 8.10 共享看板 → 8.11 问队友 → 8.12 运行中收消息（只做后端；界面 12.24 / 13.17 之后）；
  之后事件触发（7.1 的事件部分）、项目与跨用户协作（8.13–8.19）。PR #14 已合并，本分支从 main（`a31080b`）重新开始。
  - 8.9 做完：`agents_list`、`agent_status`（只读对方的运行记录），实例的用途说明和“允许其他 agent 查我、问我”开关
    （迁移 0024，`PATCH /v1/instances/{id}`，client-core `update_instance`）。
  - 8.10 做完：共享看板 `board_read`、`board_post`（迁移 0025，`/v1/board`，client-core `board` 等），每用户 200 条没归档的、
    满了最早的自动归档，归档的 30 天后删。
  - 8.11 做完（`4122327`、`78d39a4`）：`ask` 工具，问题是提问方运行下来源 `ask` 的子运行，在对方实例上跑、接着对方的会话，
    用对方自己的授权（问的是信息不是权限）、算提问方运行树的预算。提问方这一轮结束时转入“等待子任务”（`wait_code` 是
    `answer`），回答到了交还。“谁在等谁”从对方占着实例的运行顺着子运行、排队走，和委派共用（按用户加锁）；一次运行最多问
    5 次、问里套问最多 2 层；30 分钟没答完、提问方已经结束、对方关了开关的，后台或接口取消（连同回答方开的子孙）。
    迁移 0026 放宽来源约束：**老版本的 client-core 解析不了 `source: "ask"` 的运行**（严格枚举），上线前一起发版。
  - 8.12 做完（`9bb0cbb`、`7b38b85`）：排队是默认；`POST /v1/instances/{id}/runs` 带 `delivery: "interrupt"`（client-core
    `send_urgent_message`）是打断重来；排队的用户消息在 agent 下次调平台工具时捎带在结果后面。
  - 评审（2026-10-28，4 个方面各一个评审，27 条去重后每组一个反驳者核对）：成立或部分成立的修了（`a0c71f0`、文档 `87d56cb`）：
    紧急消息到的时候这一轮刚好要转入等待、退避就丢了（现在结束前锁住运行再查）、启动期间到的不再先跑旧任务；紧急消息每条打标记、
    先来后到，正在被领取的运行也锁上；回答方的产出物只看得到这个问题下面的；关交流开关和建提问用同一把锁、先锁运行再改实例；
    同一个问题按“还没交还”去重（超时以后可以再问）；交还结果这一轮断了下次重交；看板用户写的也抹保险箱的值、抹完再查长度、
    取消归档幂等且算新的；`agent_status` 直接查占着实例的运行；后台领取只领本版本认识的来源（`docs/release.md` 第 3 节加了规则）；
    给 App 的契约文档（`ask` 来源、`ask.sent`、`board.posted`、`wait_code: answer`、AI 标识规则）。
  - 修复的评审（2026-10-29，3 个方面、每条 2 个反驳者；中途撞上用量上限，恢复后续完）：成立的修了（迁移 0029）：领取时同一实例
    先领紧急消息，没人去打断的占着实例的运行由新来的紧急消息打断；结果“发给 agent”另记 `handed_at`（处理完这一轮才记已交还），
    交出去以后再问同一个问题是真的再问、重交的带续跑说明和简报；回答方发布的产出物还放在问题里，但提问方那棵树和 App 看得到
    （`artifact_scope`，同名先用树自己的）；解密保险箱挪到拿锁、开事务之前；取消整棵树之前按 id 顺序先锁运行；
    `last_finished_run` 按结束时间；测试用信号代替固定的等待，补了“拿到没回答的那一轮里再问”“会话没接回时不说看过”。
  - 第三轮（只看上一轮的修复，2026-10-29，2 个方面、每条 2 个反驳者）：成立的修了（`1d858a4`）：前面排着紧急消息时打断记在排第一
    的那条上（“被打断了”落在紧接着的那一轮、先来后到不乱）；领取时拿到锁再查一次刚提交的紧急消息；产出物范围改成“自己的加上
    下面各个问题（含问题里再问的）的回答方的”，查询走 `= ANY`、列表最多 500 条；`artifact_list` 带 `artifact_id`，读、取可以按它
    挑同名的；交还结果先记 `handed_at` 再发、记不下就重试；各条取消路径先按 id 顺序锁运行再改实例。没修：结果交出去这一轮断了、
    退避期间又有子任务做完时，重交不带续跑说明（两个反驳者意见不一，影响只是少一句说明）。
  - 没做、记着（评审判断现在不值得或要人定）：一个 agent 能把看板挤满（按作者限额，和“看板按团队、项目分”一起定）；问同一个
    队友没有总数上限（只有每次运行 5 次、30 分钟超时）；回答方触发的审批没写“谁问的”；新客户端连老服务端时 `delivery` 被忽略；
    执行器死掉时被取消的运行留下的待处理审批要等它自己过期（取消路径原来就这样）；团队负责人打断成员、Claude 钩子的中途插话。
  - **上线前必须做**：~~client-core 解析运行列表时来源、状态、种类改成宽松的~~（`182dcb2` 做了：读不了的那条跳过）；iOS、安卓把
    `RunSource.ask` 显示成“队友提问”、带 AI 标识（现在 iOS 会显示成“你”），不认识的来源别当成用户发的（12.24 / 13.17 一起做，
    这个容器里没有 Swift 和安卓工具链）。
  - 已知偶发：`crates/relay/tests/relay.rs` 的 `heartbeats_drop_revoked_frozen_and_silent_computers` 偶尔失败、重跑就过（和本批改动无关）。
  - 事件触发（7.1 的事件部分）第一版做完（`8da843c`，设计和接口见 [事件触发](../event-triggers.md)）：计划的 webhook
    （迁移 0030 `plan_hooks`、`runs.hook_id`），外面的服务往 `/v1/webhooks/<令牌>` 发 JSON 或文本，平台按计划起一次运行；建的时候要
    用户同意、令牌只给一次、库里存哈希；按 webhook、按用户每小时限流，排着的最多 5 个；计划策略加 `notify_success`（成功不打扰）。
    client-core 和安卓绑定都更新了。没做：平台自己接邮箱、IM 收消息，按服务商校验签名，平台内的事件（看板、产出物）。
  - webhook 评审（2026-10-29，安全、正确性 2 个方面，16 条每条 2 个反驳者）：成立的修了（`3de0400`，文档 event-triggers.md
    第 2、3 节）：洪水在查库前挡掉（来源地址只看不扣、每个 webhook 内存里每分钟 30 次、令牌对了才读正文）；第一次查不加锁、
    超了不解密；加锁时先锁用户再锁 webhook（2 秒等不到回 429）、按用户排队；计划每日 token 上限按最近 24 小时核对；内容加
    随机标记；飞书、Slack 的 `url_verification`；排着的事件运行不吞定时触发；有 webhook 的计划不能加步骤；删实例连 webhook
    一起删；成功不打扰的计划不远程开实时活动。没改：事件运行照样用计划的预授权（文档里写了 App 要提示）。
  - **App 那边要做**（12.x / 13.x）：iOS、安卓的计划策略模型带上 `notify_success`（改计划时整个策略一起提交，漏了会被重新
    打开）；加 webhook 时预授权里有执行命令、联网、其他或全部的要提示。
  - 下一步：项目与跨用户协作（8.13–8.19），设计评审进行中（3 个设计、3 个评委、合并、查漏）。
  - agent 自己的浏览器（2026-10-29 用户问）：调研写在 [浏览器](../browser.md)（建议自己做、AgentBay 以后当大陆浏览器）。
    用户说先设计“受管控的上网通道”（出口代理，WBS 2.7），再定浏览器：出口代理的设计评审进行中，结果写成 `docs/egress.md`，
    然后在它上面做浏览器的设计。
- 已完成：ACS 沙箱后端这一批（2026-10-28，本会话 session_016LgPcdynywrhrjCq8VVFLt，用户定“1、省钱；2、解绑；3、写”）写完了：
  envd 客户端拆到 `envd.rs`（`7beff64`）；`AcsProvider` + 模拟测试，创建时要 Pod IP、拿不到就删沙箱（`0d472b5`）；没有卷的后端
  不乱删沙箱、运行中换地址会记下（`a7ddfe6`）；`[sandbox.acs]`、`THINKTIN_ACS_API_KEY`、`docs/sandbox-acs.md`（`531c38a`）；
  令牌跟着地址走的测试（`f108708`）；`[sandbox.lifecycle]` 计时、`pause_waiting_approval`（`2acd2d9`）；归档的分块加密
  （`ead254a`）；对象存储大文件流式（`37a3745`）；沙箱流式写文件、本地无卷模式（`077bac4`）；迁移 0023（`a612d44`）；控制服务
  归档、放回，巡检每个实例单独事务（`111318f`）；`ObjectWorkspaceStore`（`0790153`）；`[sandbox.workspace]`（`732595c`）；
  预热归档了的实例（`326f7e3`）；东京部署配置（`5367a55`）。部署时要定的见交接文档第 4 节第 9 条。
- 对抗式评审（2026-10-28，5 个方面各一个评审、每条 3 个反驳者）：19 条，18 条成立，按 11 个问题修了：模型网关升级卡住（`945ef65`）；
  去掉不起作用的 `paused_retention`、出网规则带端口启动报错、安全组只许 VPC 连 8790、Cube 不用卷要对象存储（`139bd0f`）；
  ACS connect 404 先查一下（`aef6f6b`）；存、放工作区不再锁着实例，“正在放回”的标记防孤儿沙箱，失败后 6 小时内不重试，
  换版本存不下时保留旧版本，清理触发器只认用户自己的前缀、业务角色只能改 8 个列，临时文件有总预算（`2503de6`）；文档（`e984e8f`）。
  全量测试 73 组通过。
- 第二轮评审（只看修复，2026-10-28）：上一轮有 6 条没修彻底，又找出 13 条，全部修了：出网规则按 sandbox-manager 的校验来
  （`6c223b5`）；安全组规则包括 VPC 的附加网段（`5dbe966`）；一个实例同时只存一份（上传期间刷新标记，别处跳过或等着）、
  存之前确认期间没被用过、记归档和删沙箱一起锁着做、删沙箱失败不算归档失败、没人要的上传自己删、放回被取消马上清理、
  标记用当下的时间并定时刷新（进程被杀的 2 × `op_timeout` 后清理）、删不掉的沙箱留着标记下次再删、要的就是现在的版本时
  存不下就不重建、临时空间存放各一半（存之前先占好）、启动检查和运行时同样取整、临时目录按进程加锁（死进程的启动时删）、
  报错去掉控制字符（`47a8a03`）。新增 7 个回归测试（`crates/control/tests/workspaces.rs`）。全量测试 73 组通过。
- 第三轮评审（只看第二轮的修复，5 个评审 + 8 个反驳者）：19 条全部确认修好；新发现 4 个评审各自找到同一个高危问题——
  记归档和删沙箱放在一个事务里，删完、提交前被打断就丢了最新的改动——已改成先提交归档再删沙箱。另外：存工作区被打断时
  马上把沙箱暂停回去、清掉待定的上传；库里暂停着、沙箱其实在跑的，归档失败也暂停回去；新建的沙箱从建好起就有人收拾；
  调小上限前存的大归档放回时借用存的一半；业务角色新建实例时也写不了沙箱、归档列（`6baa66a`、`c3ba1e9`、`d4303d1`）。
- 第四轮评审（只看第三轮的修复，3 个评审 + 每条 2 个反驳者）：都确认修好；新的 3 条修了：记活动用当下时钟（不然锁着等的唤醒
  记的时间比归档早，之后的归档会跳过保存直接删沙箱）；归档记下之后出的错按“没删掉沙箱”处理（不记失败、不退版本）；
  停机时等收拾任务做完再关连接池（`6d4c527`、`9f81383`）。另一条（大归档放回占满放的一半）两个反驳者都不认。
- 第五轮评审（只看第四轮）：3 条都确认修好；又有 2 条低危，修了：只差删沙箱的快速路径删完库出错也不退版本；停机时从开始
  守着就算一个收拾，执行器里稍后才被取消的运行也等得到。之后不再开评审轮：每轮只剩更窄的低危边角。

下一步（要 macOS 才能验，或者要人定）：
0. **部署到阿里云新加坡**（2026-10-27 定）：只读检查 `deploy/aliyun/run.sh check` 全部通过；第 1 阶段网络已建（不收费，ID 见 [新加坡部署计划](../deploy-aliyun-sg.md) 第 8.6 节）。沙箱实测脚本 `deploy/aliyun/run.sh sandbox [--apply]` 已写好，用假 Key 试过。**卡在实名认证**：国际站账号开通智能体沙箱极速版前要实名，用户在选国际站认证还是换国内站账号。认证、开通、建 API Key 放进环境变量 `ALIYUN_SANDBOX_API_KEY` 后，开新会话先 `run.sh sandbox` 再 `--apply`，结果记进第 8.6 节。暂停要申请白名单（第 8.7 节），实测时一并确认。之后的阶段先列资源和费用请用户确认再动手。
1. macOS App 已经在真 Xcode 上编过（见上），还没在 Mac 上跑过：截图、键鼠、登录项、Secure Enclave、Sparkle 要在 Mac 上过一遍；`macos-release.yml` 没跑过（证书、公证密钥、Sparkle 密钥、
   更新源地址要人准备，见 `docs/macos.md` 第 6 节）。还能在这里做的小项见 `docs/macos.md` 第 8 节（工具调用中的提示、
   审批说明本地化）。
2. iOS 控制中心的“全部停止”要让小组件扩展共享登录会话（钥匙串共享），要人定安全上能不能这样。
3. 要人定的事见下面“坑和决定”（推送 SDK、上架材料、审批不设锁屏密码时两端不一致等）。

环境（容器回收后要重装）：Swift 6.2 装在 `/opt/swift`（swift.org 的包，验签）；Android SDK 在 `/opt/android-sdk`（cmdline-tools、platform 35、build-tools 35.0.0，不用 NDK）；`cargo build -p client-core --lib` 出本机库，`tools/client-core/build-linux-swift.sh target/linux` 出 Linux 版 Swift 包。Gradle 直连 Maven Central 没被限流。Gradle 和 Swift 一起跑时 Robolectric 偶尔超时，分开跑。

坑和决定：
- 原来三个会话（backend `session_016LgPcdynywrhrjCq8VVFLt`、iOS `session_01GuCp3KRgqaK6Kzynw6udRn`、安卓 `session_01T2zubC6hDr9ZZR3ihhPP5b`）查不到了，它们 scratchpad 里的工作流脚本和缓存也没了，按各进度文件重新来。
- 定时任务：每小时的“ThinkTin 续跑检查”（`trig_01J9YurHAZJ35AugopCVXWKZ`）10-26 20:59 删了——能在这里做的都做完了，剩下的要部署
  环境、Mac 或人定。
- Codemagic：API 令牌用户在聊天里给的，只存在会话的临时目录（不进仓库）；用完要在 Codemagic 上作废换新的。应用 id
  `6adfea4501e42548bf7801f4`；`POST https://api.codemagic.io/builds`（`appId`、`workflowId`（`apple-check` / `apple-package` / `ios-screenshots`）、`branch`）发起，
  `GET /builds/<id>` 看状态，日志在每一步的 `subactions[].logUrl` 和日志包（`artefacts`）里。免费额度每月 500 分钟。
- 要人定的：iOS 批准审批时设备没设锁屏密码照常批准（`BiometricGateResult.unavailable`），安卓是不许批准，两端不一致。
- 要人定的（上架，docs/android-release.md 第 2.2、4、5 节）：审核账号（服务端要有固定验证码的审核账号）、生成式 AI 的备案 / 登记材料、
  APP 备案号、Play 是否用同一把签名密钥。
- 要人定的：安卓推送 SDK（极光闭源、FCM 带 Play 服务许可，和安卓“只用宽松许可证”的约定冲突；极光的权限和 Robolectric 不兼容），详见 `docs/progress/android-app.md`。现在两个渠道的 `FlavorPush` 是空实现。
- Robolectric 的触摸点不到盖在页面上的面板（会落到遮罩上，真机正常）：面板里的控件在测试里用 `SemanticsActions.OnClick`（安卓 README 已知问题）。

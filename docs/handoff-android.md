# 交接：安卓端（2026-10-29 16:00 UTC，周额度快用完）

上一个会话是 Android 会话（session_01T2zubC6hDr9ZZR3ihhPP5b），因为周额度快用完紧急交接。分支 `android-app`，进度文件 [docs/progress/android-app.md](progress/android-app.md)。下一个 agent 从这里接着干。

## 1. 先看这几条（和用户相处的规矩）

- 用中文、说人话。用户不是做底层技术的，不要堆术语和长段落。
- **GitHub 上的代码为准。** 用户明确说过：不要把本地旧代码推上去覆盖远端。开工先 `git fetch`，以 `origin/main`、`origin/android-app` 为准。
- **对外的、改仓库外状态的实验先问再做。** 上一个会话为了试会话页面的行数统计，开过一个零改动的测试 PR #15 又关掉，用户看到红色标记不高兴（PR 删不掉）。以后这种事先问。
- 会话页面上“新增 26 万行”是 PR #7 合并时定死的统计，改不掉，用户已经知道，不用再解释。
- 是否开 PR 由 agent 自己决定（用户原话：“是否需要创建PR，你自己决策就好”）。
- 提交信息结尾按会话给的署名行写，不写其他模型名；小步提交、马上推送（CLAUDE.md）。
- 用户说“先停”“等我通知”时就停，不要自己续跑。

## 2. 现在的状态

- `main` 在 `a31080b`（PR #14 阿里云部署合并后）。安卓 13.1–13.16 全部在 main 里：13.1–13.4、13.16 是本会话做的；13.5–13.15 是集成分支 `claude/determined-lovelace-vn0j5h` 上另一个会话补的，**没评审过**。
- `android-app` = main + 几个提交：合并 main（`d21d322`）、认领（进度文件）、开源许可测试修复（`a199fd3`）、评审结果（`bb139de`）和本交接。和 main 的代码差异只有 `a199fd3` 那一处（许可证清单来源经 `AppContainer` 注入，界面测试不再依赖本机有没有同步过清单）。
- CI：`android.yml` 在 `d21d322` 上是绿的。
- 本机基线（合并 main 后、修复前）：`:app` 354 个测试（修了许可那一个后全过）、`:data` 180（+release 变体 180）、`:design` 17、`:core` 8；lint 0 错误、39 个警告。
- 测试 PR #15 已关闭（不要合并、不要重开）。

## 3. 正在做的：评审并修复 13.5–13.15

**评审已经做完**，结果在仓库里：[docs/review/android-13x/README.md](review/android-13x/README.md)（可读清单）+ 同目录 8 个 `<组名>.json`（完整描述、证据、建议修法、核实记录）。65 条：18 条已核实成立、6 条 high / medium 没核实成、40 条 low 没核实（另有 1 条已驳回，已剔除）。

最要紧的（已核实成立）：

1. 对话页打开后新到的审批请求，内嵌审批卡按钮全灰（审批记录从不补拉）。参照 iOS `ConversationModel.checkApprovals`。
2. 对话页的停止键对委派子运行也停整棵树，连负责人在别的实例里的运行一起停，没有确认。
3. 计划编辑：保存中能关页面（协程被取消，计划留成半截）；触发器“先删后加”，服务端拒绝新规则时旧规则已没了。
4. 团队详情编辑后返回不刷新；团队编辑页加载失败显示成空表单；流水线步骤键名输入中暂时重名时，依赖被联动改到错的步骤。
5. 电脑审批的推送和收件箱条目到不了审批中心；“账号已解冻”推送点开后仍停在冻结页。
6. 重新配对 / 生成新密钥时只在本机把令牌标成吊销，电脑那边没作废；录入新指纹后密钥失效，“生成新密钥”按钮出不来（high）。
7. 常驻通知：Activity 重建（旋转、换语言）时全撤；进程重启不对账；Android 14 划掉后又发回来。
8. 开源许可页 App 依赖名写死中文；系统“应用语言”改回默认时 App 不跟随。

没核实成的 6 条（先核实再修）：清单 JSON 深层嵌套导致 StackOverflowError 崩溃（标 high，官网包每次启动都崩）、自动更新提示框 Activity 重建后消失、保险箱编辑时残留已删除实例 id、IM 换地址允许换平台（服务端 422）、IM 重复绑定 409 文案错、系统语言非中英时界面和服务端语言不一致。

**修复进度**：上一个会话启动了一个修复工作流，按 A–H 8 组顺序修，每组自测、提交、推送。交接时第 A 组刚开始，**还没有任何修复提交**。工作流是会话内的，新会话没法续跑，按下面第 4 节重新来。看 `git log origin/android-app` 里 `bb139de` 之后有没有以“Android 13.x”开头的修复提交，有的话那几组已经做了（提交信息里写了修了哪些），对照 JSON 跳过已修的条目。

如果 `origin/autosave/android-app` 比 `origin/android-app` 新，说明上个会话有没提交的修复改动，先按 CLAUDE.md 用 `.claude/hooks/autosave.sh --restore android-app` 恢复。

## 4. 下一步（按顺序）

1. `git fetch origin && git checkout android-app && git pull`；看第 3 节判断修到哪了。
2. 搭环境（见第 5 节），跑一遍基线确认现状。
3. 按 A → H 逐组修：读 `docs/review/android-13x/<组>.json`，confirmed 直接修；unverified / low 先核实。每条修复配测试，中英文文案都加，只改 `apps/android/**`。每组提交、推送一次。
   - 各组的提示（上个会话给修复员的）：
     - A：审批记录在 `agent.permission_requested` / `run.state` 进入 waiting_approval 时按 approval_id 补拉；停止键对子运行只停自己（`wholeTree = parentRunId == null`），网关返回的根运行不是本实例的别塞进 runs；把 ChatTestSupport 假服务的 cancelRun 改成和网关一致（tree 时返回根）。
     - B：保存中 `requestClose()` 直接返回、关闭按钮禁用；触发器在总数不超 10 条时先加后删；`FREQ=MINUTELY` 本地拦截；“只补一次”的文案按服务端恢复语义改。
     - C：TeamDetail 用 ViewModel 里的 `shownOnce` / `onShown()`（同 TeamsScreen、PlanDetail）；TeamEdit 显示 loadError + 重试；`PipelineSteps` 的 rename / remove 只在旧键名唯一时联动依赖（实际行号 rename 114–123、remove 126–129）。
     - D：电脑审批推送 / 收件箱条目落到审批中心（`InboxTargets`、`PushMessage` 同一根因）；account_restored 推送重查账号；重新配对 / 换密钥前先发吊销；`KeystoreSigner.publicKey()` 探测密钥失效，让“生成新密钥”出来；配对深链限长。
     - E：`AppRoot` 的 DisposableEffect 不在 Activity 重建时 stopAll；启动时对账残留通知；加 deleteIntent；通知文案 / 渠道名用按 App 语言本地化的 context；渠道被关时 `show()` 返回 false。
     - F：`APP_DEPENDENCIES` 名字进 strings；系统“应用语言”改回默认时跟随；NOTICES.md 入口；只在语言列表真变了才重设 Accept-Language；撤回同意时清产出物缓存和电脑配对数据。
     - G：清单解析把 StackOverflowError 当无效清单（或限深度 / 大小）；关掉 HttpURLConnection 自动跟随重定向、重定向目标也过 host 检查；API 28 读不到签名就拒绝安装；提示框状态放到 ViewModel / 容器里、允许取消下载；`update-manifest.py` 检查是 direct 渠道的包。
     - H：先核实三条 unverified；Mock 的 confirmPlan 409、IM 换平台 422、重复绑定 409 和服务端对齐；审批通知的“拒绝”快捷按钮（拒绝不需要生物识别），牵扯大就跳过；README 过时的地方更新。
4. 全部修完：全量 `test lint assembleDebug :app:assembleCnRelease`（命令见第 5 节），过了再推。
5. 更新 `docs/progress/android-app.md`（“已完成”加一段评审修复，“进行中”改掉），推送。
6. 开 PR：`android-app` → `main`，正文写修了哪些、跳过哪些和理由。然后盯 CI 到绿。
7. 之后没有排定的安卓工作，等用户安排。13.17 agent 交流界面、13.18 项目界面用户说先不开工。

## 5. 环境（新容器要重装）

- Android SDK、NDK r27c、cargo-ndk 装在 `/opt/android-sdk`；新容器可能没有，按 `apps/android/README.md` 装。
- `apps/android/local.properties` 写 `sdk.dir=/opt/android-sdk`（已被 .gitignore 忽略，新容器要自己建），或者设 `ANDROID_HOME`。
- Maven Central 经代理会 429：在 `~/.gradle/init.d/aliyun-mirror.gradle` 放阿里云镜像（只影响本机，内容见 `docs/progress/android-app.md` 的“坑和决定”）。
- 只有 JDK 21（没有 17）。同一时间只跑一个 Gradle。
- 先 `cargo build -p client-core` 出 `target/debug/libclient_core.so`（CoreSmokeTest 经 JNA 调它）。
- 全量命令：
  ```
  cd apps/android && ANDROID_HOME=/opt/android-sdk THINKTIN_CORE_LIB_DIR=$PWD/../../target/debug THINKTIN_REQUIRE_CORE=1 ./gradlew --no-daemon test lint assembleDebug :app:assembleCnRelease
  ```
- 单个测试类：`./gradlew --no-daemon :app:testCnDebugUnitTest --tests 'cn.thinktin.app.ChatViewModelTest'`。Robolectric 界面测试一个类要 1–3 分钟。
- 绑定一致性：`apps/android/scripts/sync-core.sh --check`（交接时是一致的）。
- 本机 jniLibs 里的三个 ABI .so 是旧的，打真机包前要 `sync-core.sh` 全量重编；单元测试和 CI 不受影响。

## 6. 要人定的（不是代码问题）

- 推送 SDK（13.8、13.12 厂商参数）：极光闭源、FCM 带 Play 服务许可，和“只用宽松许可证”冲突，要法务点头和 AppKey / Firebase 项目。代码接口已留好，定了只改各渠道的 `FlavorPush`。
- 上架材料（13.11）：商店资料、备案、审核账号。后端放境外，国内备案难，目前计划先不上国内商店。
- 13.9 配对要电脑端（14.8）和真机才能端到端试。

## 7. 别的线

- 部署（阿里云东京、ACS 沙箱）见 [docs/handoff.md](handoff.md)，和安卓无关。
- `origin/autosave/*` 是自动快照分支，分支合并后可以在网页上删（git push 删不了远程分支）。

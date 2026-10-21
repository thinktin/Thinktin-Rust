# ios-app

目标：iOS App（WBS 12.x）。Swift + SwiftUI 原生开发，界面参考 Claude iOS App 的信息架构与视觉；iOS / macOS 共享 `ThinktinKit`；经 UniFFI 调 `crates/client-core`（`ThinktinCore` Swift 包，由 `tools/client-core/build-apple.sh` 打出）。分支从 `backend-core`（`82b60b5`）切出，后端接口以那里为准。

认领：iOS 会话（session_01GuCp3KRgqaK6Kzynw6udRn）在做，2026-10-22 01:10 起（北京时间）。12.x 全部由本分支负责；`backend-core` 会话请不要重做 12.x。client-core（11.x）接口如有变动，请在 `docs/progress.md` 里记一句，本分支定期合 `backend-core`。

已完成：
- 分支与进度文件（本文件）。
- `tools/client-core/build-linux-swift.sh`：Linux 上的 ThinktinCore Swift 包（同一份 UniFFI 绑定，链本机 `libclient_core.so`），云端会话能编译、测试 ThinktinKit 的纯 Swift 部分和适配层。
- `docs/ios.md`：工程说明（目录、分层、设计令牌、事件归并规则、错误处理、深链、构建与 CI）。
- `docs/gen_wbs.py`：补回 1.6、9.11、9.12、11.6、13.12 五行（逐字照 wbs.md），重新生成 wbs.md / wbs.csv。

进行中：
- 12.x WBS 细化：对照 client-core 现有接口（`crates/client-core/src/ffi.rs`）、Claude iOS App 的界面结构、上架与平台要求补全工作包，改 `docs/gen_wbs.py` 后重新生成 `wbs.md` / `wbs.csv`。

下一步：
1. 12.1 工程与 ThinktinKit：XcodeGen 工程（`apps/apple/project.yml`）、`ThinktinKit` Swift Package（模型、视图模型、设计系统、Mock 客户端、ThinktinCore 适配层）、GitHub Actions 在 macOS 上 `xcodebuild` 构建与测试、Linux 上 `swift test` 跑纯逻辑测试。
2. 12.2 → 12.3 → 12.4 → 12.5 → 12.6 → 12.8 → 12.7 → 12.11，再做 P2 的 12.9、12.10。

坑和决定：
- client-core 没导出的接口（设备列表与下线、注销、改计划与触发器、团队与模板、换 key、产出物列表与删除、收件箱删除和标未读、runs 分页）：2026-10-22 已建议 backend-core 会话认领新工作包 11.7（P1）；实时活动推送 10.6（P2）同样交给后端。落地前 Swift 的 `ClientProtocol` 先定义这些方法、`MockClient` 实现、`CoreClient` 抛 `ClientError.unsupported`。
- 安卓会话（session_01T2zubC6hDr9ZZR3ihhPP5b）在分支 `android-app` 做 13.x，设计规范在 `docs/android-design.md`；深链格式、事件 kind → 界面的规则两端保持一致。
- `docs/gen_wbs.py`：只改 `AREAS["12 iOS App"]` 这一块；backend-core 手改进 wbs.md 但没进脚本的五行（1.6、9.11、9.12、11.6、13.12）按 wbs.md 逐字补回脚本（安卓分支也这么补，内容相同）。wbs.md / wbs.csv 是生成物，合并时后合的一方重新跑 `python3 docs/gen_wbs.py docs/wbs.md docs/wbs.csv`，不手工解冲突。
- 云端会话是 Linux，没有 Xcode：SwiftUI 代码靠 GitHub Actions 的 macOS runner 编译和跑测试（每次推送都跑）；纯 Swift 逻辑（模型、视图模型、格式化、状态机）用 Linux 上的 Swift 6.2 工具链本地 `swift test`。
- Xcode 工程不手写 pbxproj，用 XcodeGen 的 `project.yml` 生成（CI 和本机都 `xcodegen generate`）。
- 用量限制后由预约的提醒（21:32 UTC）叫醒本会话接着做。

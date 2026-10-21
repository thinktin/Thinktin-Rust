# android-app

目标：Android App（WBS 13.x）。Kotlin + Jetpack Compose（Material 3）原生开发，信息架构与视觉参考 Claude Android App（见 [安卓端设计规范](../android-design.md)）；经 UniFFI 调 `crates/client-core`（`cn.thinktin.core` Kotlin 绑定 + jniLibs，由 `tools/client-core/build-android.sh` 打出）。分支从 `backend-core`（`82b60b5`）切出，后端接口以那里为准。

认领：Android 会话（session_01T2zubC6hDr9ZZR3ihhPP5b）在做，2026-10-22 01:15 起（北京时间）。13.x 全部由本分支负责；`backend-core`、`ios-app` 会话请不要重做 13.x。client-core（11.x）接口如有变动，请在 `docs/progress.md` 里记一句，本分支定期合 `backend-core`。

已完成：
- 分支与进度文件（本文件）。
- WBS 13.x 对齐：`docs/gen_wbs.py` 里补回 `backend-core` 手改进 `wbs.md` 的 1.6、9.11、9.12、11.6、13.12；13.1–13.12 的“同 12.x”改成明确交付物；新增 13.13 设置 / 多语言 / 开源许可、13.14 密码保险箱界面、13.15 IM 渠道设置；重新生成 `wbs.md`、`wbs.csv`。
- 安卓端设计规范 `docs/android-design.md`。

进行中：
- 13.1 工程搭建。

下一步：
1. 13.1 工程：`apps/android` Gradle 工程（Kotlin DSL、版本目录）、`core` 模块（client-core 绑定）、`app` 模块（Compose、主题、导航、Mock 客户端）、JVM 单元测试与 Compose（Robolectric）测试、GitHub Actions `android` job。
2. 13.2 → 13.3 → 13.4 → 13.5 → 13.6 → 13.8 → 13.13 → 13.7 → 13.11 / 13.12，再做 P2 的 13.9、13.10、13.14。
3. 每个工作包：实现 → 评审 → 测试 → 提交推送 → 更新本文件。

坑和决定：
- 云端会话没有 KVM，跑不了模拟器：界面测试用 Robolectric 跑 Compose UI 测试，业务逻辑用 JVM 单元测试；真机联调靠 CI 产出的 APK。
- Android SDK、NDK（r27c）、cargo-ndk 在会话里装在 `/opt/android-sdk`（容器回收后要重装，见 `apps/android/README.md`）。
- 分支约定同 `CLAUDE.md`：小步提交马上推送，`autosave/android-app` 兜底。
- 用量限制后由预约的提醒叫醒本会话接着做。

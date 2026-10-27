# ios-testflight

目标：iOS 第一次上 TestFlight（WBS 12.19 的落地）。用户 2026-10-28 在开发者网站操作，Claude 负责流程和上传。

已完成：
- 用户建好了 App Group `group.cn.thinktin.Thinktin`；团队 id `5BUH46M229`（Siting (Shenzhen)）。
- `ios-release.yml`：私钥可以直接粘贴 `.p8` 内容（`ASC_KEY_P8`，换行丢了也行，读不出私钥时报错；旧的 `ASC_KEY_P8_BASE64` 照样认），团队 id 不配就用 `TEAM_ID_DEFAULT`；`docs/ios-release.md` 第 1 节改成新的准备步骤。

- 用户建好了 App 记录（ThinkTin，`cn.thinktin.Thinktin`）、API key，`testflight` 环境里放了三个密钥（2026-10-28）。
- 发布工作流第一次跑就停在算版本号：macOS 的 /bin/bash 3.2 把 `$version` 后面的中文逗号当成变量名（`4c84bcb` 加大括号，macos-release.yml 同样两处）。
- 演示版开关：构建设置 `THINKTIN_CLIENT` → Info.plist `ThinktinClient`，`AppConfiguration.clientKind` 认它（环境变量优先，空的按构建配置）；发布工作流手动触发加 `demo` 选项。服务器（`api.thinktin.cn`）还没上线，给用户先试的 TestFlight 版用演示数据。

进行中：只归档的试跑（run 40565563995，`4c84bcb`）确认密钥和签名。

下一步：
1. 试跑通过后，手动触发 demo + upload，传第一个演示版到 TestFlight；内部测试组加用户本人。
2. 服务器上线后打 `ios-v0.1.0` 标签发连服务器的版本。
3. `uicheck/run.sh test` 只编不跑 ThinktinTests（App 的测试，要 App 包的那些在 Linux 上本来就过不了）；单独跑 `swift test --skip-build --filter ThinktinTests.*clientKind`。
4. 跑通后开 PR 合进 main（用户说合并才合）。

坑和决定：
- 构建只能在 Mac 上做（GitHub 的 macos-26 机器），所以 key 放 GitHub 的环境里，不放云端会话的环境变量（会话是 Linux，也编不了 iOS）。
- 手动触发能选分支跑，不用先合进 main；标签发版用的是标签所在提交里的工作流。

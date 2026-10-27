# ios-testflight

目标：iOS 第一次上 TestFlight（WBS 12.19 的落地）。用户 2026-10-28 在开发者网站操作，Claude 负责流程和上传。

已完成：
- 用户建好了 App Group `group.cn.thinktin.Thinktin`；团队 id `5BUH46M229`（Siting (Shenzhen)）。
- `ios-release.yml`：私钥可以直接粘贴 `.p8` 内容（`ASC_KEY_P8`，换行丢了也行，读不出私钥时报错；旧的 `ASC_KEY_P8_BASE64` 照样认），团队 id 不配就用 `TEAM_ID_DEFAULT`；`docs/ios-release.md` 第 1 节改成新的准备步骤。

进行中：等用户建 App Store Connect API key（Admin），在 GitHub 的 `testflight` 环境里放 `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_P8`。

下一步：
1. 用户配好后，在本分支手动触发 iOS release（不上传）：确认能归档，自动签名登记 bundle id 和能力。
2. 用户在 App Store Connect 建 App 记录（`cn.thinktin.Thinktin`）。
3. 勾上传再跑一次，或打 `ios-v0.1.0` 标签；内部测试组加用户本人。
4. 跑通后开 PR 合进 main（用户说合并才合）。

坑和决定：
- 构建只能在 Mac 上做（GitHub 的 macos-26 机器），所以 key 放 GitHub 的环境里，不放云端会话的环境变量（会话是 Linux，也编不了 iOS）。
- 手动触发能选分支跑，不用先合进 main；标签发版用的是标签所在提交里的工作流。

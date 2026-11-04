# ios-release-precheck
目标：TestFlight 发版先在 Linux 上验 App Store Connect 的密钥和苹果协议，不用先等 macOS 机器。
已完成：
- 新作业 `key-check`（ubuntu-latest，“Test flight” 环境）：装密钥、跑 `tools/apple/asc_key_check.py`；macOS 的 `testflight` 作业 `needs: key-check`。
- 装密钥的逻辑抽成 `tools/apple/asc_install_key.sh`（bash 3.2 能跑），`key-check`、`testflight`、`testers` 三个作业共用。
- macOS 作业不再重复检查；PyJWT 改在“Signing certificate and profiles”这一步装。
- Linux 上的检查跑通了（run 24、25）：密钥、Bundle ID、证书都是 200，苹果的新协议用户已经同意（之前是 403 PLA_NOT_ACCEPTED）。
- Codemagic 备用：`codemagic.yaml` 加 `ios-testflight`（和 GitHub 的 testflight 作业同样的步骤；证书在 publishing 脚本里撤销，
  构建失败也跑）；`ios-release.yml` 加输入 `builder`（github / codemagic）和作业 `codemagic`（Linux 上发起、跟踪，
  `tools/apple/codemagic_build.py`，只用标准库，假的 Codemagic 接口上测过成功、失败、401、没令牌）。说明在 docs/ios-release.md 2.2。
进行中：run 25（macos-26）在排 GitHub 的 Mac；Codemagic 那条路等用户配两处（GitHub 的 THINKTIN_AI_CODEMAGIC_API_KEY、
  Codemagic 的 testflight 变量组）。
下一步：用户配好就 `builder=codemagic` 跑一次；用户说“合并”再合进 main。
坑和决定：
- 2026-11-04 16:05–16:49（UTC）GitHub Actions 故障，run 21（Intel）、22（arm64）都排不上 macOS 机器，15 分钟后被取消。
- 用户说配了 Codemagic 的密钥，但这个会话里读不到（调 Codemagic 接口回 401）：云端环境里加的变量只有新会话才读得到；变量名不能带点。
- Codemagic 的 API 令牌：用户放在云端环境变量 `THINKTIN_AI_CODEMAGIC_API_KEY` 里（新会话才读得到）。用法 `curl -H "x-auth-token: $THINKTIN_AI_CODEMAGIC_API_KEY" https://api.codemagic.io/apps`，不打印它的值。

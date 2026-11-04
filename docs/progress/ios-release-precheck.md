# ios-release-precheck
目标：TestFlight 发版先在 Linux 上验 App Store Connect 的密钥和苹果协议，不用先等 macOS 机器。
已完成：
- 新作业 `key-check`（ubuntu-latest，“Test flight” 环境）：装密钥、跑 `tools/apple/asc_key_check.py`；macOS 的 `testflight` 作业 `needs: key-check`。
- 装密钥的逻辑抽成 `tools/apple/asc_install_key.sh`（bash 3.2 能跑），`key-check`、`testflight`、`testers` 三个作业共用。
- macOS 作业不再重复检查；PyJWT 改在“Signing certificate and profiles”这一步装。
进行中：从本分支手动触发一次（upload、demo），看 Linux 上的检查结果。
下一步：用户说“合并”再合进 main。
坑和决定：
- 2026-11-04 16:05–16:49（UTC）GitHub Actions 故障，run 21（Intel）、22（arm64）都排不上 macOS 机器，15 分钟后被取消。
- 用户说配了 Codemagic 的密钥，但这个会话里读不到（调 Codemagic 接口回 401）：云端环境里加的变量只有新会话才读得到；变量名不能带点。

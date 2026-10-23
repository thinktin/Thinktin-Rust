# 上游 agent 漏洞响应（WBS 15.5）

沙箱里跑的 agent（Claude、Codex、Pi、OpenClaw、Hermes）都是上游开源项目。上游出了高危漏洞时，目标是**一天内**让所有实例换到修复后的版本；修复版还没出时，先让受影响的版本停下来。用户的模型 key 不进沙箱（模型网关换 key），这是漏洞期间的兜底。

## 负责人

每个内置 agent 指定一个负责人和一个备份，名单放在内部值班表里（不进仓库）。负责人要做的：

- 订阅上游的安全公告（GitHub Security Advisories、发布说明、邮件列表），以及 agent 依赖的运行时（Node、Python）的公告。
- 收到公告后 2 小时内判断是否影响我们：受影响的版本、利用条件（沙箱默认断网只放行模型网关，很多远程利用条件不成立）、可能泄露什么（工作区文件、保险箱里注入过的值、沙箱令牌）。
- 主导下面的流程，结束后写复盘。

| agent | 清单 | 上游 |
|---|---|---|
| Claude（ACP / CLI） | `crates/catalog/manifests/claude.toml` | agentclientprotocol/claude-agent-acp（内含 Claude Agent SDK） |
| Codex | `crates/catalog/manifests/codex.toml` | agentclientprotocol/codex-acp（内含 @openai/codex） |
| Pi | `crates/catalog/manifests/pi.toml` | earendil-works/pi（@earendil-works/pi-coding-agent，适配器 pi-acp） |
| OpenClaw | `crates/catalog/manifests/openclaw.toml` | openclaw/openclaw |
| Hermes | `crates/catalog/manifests/hermes.toml` | NousResearch/hermes-agent |

## 流程

1. **定级**（2 小时内）。高危：能在沙箱里拿到别的用户的数据、逃出沙箱、读到注入的保险箱值或沙箱令牌、绕过审批执行工具。其他按普通升级走（下个发版带上）。
2. **有修复版**：
   1. 按 WBS 6.7 的版本规则升级清单：旧清单移到 `manifests/archive/<id>-<版本>.toml`、登记进 `ARCHIVED`，新版本写进 `manifests/<id>.toml`；构建并发布新模板（6.8 的模板流水线）。
   2. 把有漏洞的版本登记进 `crates/catalog/src/lib.rs` 的 `WITHDRAWN`（agent id、版本、公告编号），和新清单同一个发版上线。
   3. 上线后，锁在下架版本上的实例**下次唤醒时自动换到当前版本**、按新模板重建沙箱（工作区卷保留），每个实例记一条 `instance.version.withdrawn` 审计（从哪个版本到哪个版本、公告编号）；下架的版本不能再领养、不能升级或回滚到它。正在跑的那一轮跑完当前这次尝试，下一轮就用新版本。
   4. 用 `thinktin-server admin versions` 看进度：每个版本上还有多少实例，下架的版本标成 `withdrawn`。空闲的实例要等它下一次运行才换过去，不影响安全（不运行时沙箱里没有 agent 进程）。
3. **还没有修复版**（当前版本本身有漏洞）：把当前版本也登记进 `WITHDRAWN` 发版。之后这个 agent 不能领养，已有实例的运行直接失败（原因写明版本已下架），计划照常触发、照常失败通知，直到修复版上线后移出名单。需要更快止损时，可以先在出口网关（2.7）层面收紧，或者对受影响的账号用 `admin freeze`。
4. **事后**：确认 `admin versions` 里下架版本的实例数降到只剩长期不用的；评估需不需要通知用户（比如漏洞可能读到工作区文件）；复盘记进安全审计记录。

## 演练

每季度对一个 agent 演练一次，计时“收到公告 → 新模板上线 → 活跃实例全部换过去”，目标一天内。演练用一个假的公告：

1. 在预发环境把当前版本的清单复制一份改成新版本号（模拟修复版），旧版本登记进 `WITHDRAWN`，走一遍正常发版。
2. 看 `admin versions`：有计划的实例在下一次触发时换过去；手动给几个空闲实例发任务，确认唤醒时重建、工作区文件还在、任务能跑完。
3. 试着用接口把实例回滚到下架的版本，应当被拒绝；用这个 agent 新领养，应当拿到新版本。
4. 记录各步用时，写进演练记录。

自动测试守住的部分：下架的版本不再列出、取不到（`catalog` 单元测试）；实例唤醒时换到当前版本并记审计、当前版本也下架时拒绝领养和启动（`crates/control/tests/lifecycle.rs`）；`admin versions` 的统计（`crates/server/tests/admin.rs`）。

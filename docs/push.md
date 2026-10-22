# 推送

系统推送（APNs、FCM、极光）的载荷和 App 的约定（架构方案 8.3，WBS 10.1、10.4、10.7）。实时活动见
[实时活动](live-activities.md)，IM 群提醒见 [IM 渠道](im-channels.md)。

每条通知先写进收件箱、再进出箱，由后台投递器发到用户每台登录着、有推送令牌的设备。推送只带标题、摘要和 id，不带对话正文；
推送可能丢，收件箱不会。

## 1. 通道和令牌

- App 登录（`login` 的 `push_channel` / `push_token`）或令牌变了（`set_push_token`）时报上通道和令牌。通道：`apns`、
  `apns_sandbox`、`fcm`、`unipush`（极光）。
- iOS 的开发证书签名的包（Xcode 直装，`aps-environment` 是 `development`）拿到的是 APNs 沙盒环境的令牌，报
  `apns_sandbox`；TestFlight、App Store 的包报 `apns`。服务端 `[push.apns]` 的 `endpoint`（默认生产环境）和
  `sandbox_endpoint`（默认沙盒环境）共用一把 .p8 密钥，按设备报的通道发。报错了环境的令牌会被 APNs 判成
  `BadDeviceToken` 清掉。
- 推送服务说令牌失效了（410、`BadDeviceToken`、`Unregistered`……）就清掉，App 下次报上新的才再发。同一个令牌登记到
  别的设备（换了账号）时，旧设备上的清掉。

## 2. 种类

`tt.kind`（Android 是 `tt_kind`）和收件箱条目的 `kind` 一样。以后可能加新的，不认识的按 `info` 显示。

| kind | iOS category | APNs 优先级 | iOS 打断级别 | Android | 发到 IM 群 |
| --- | --- | --- | --- | --- | --- |
| `run_finished` | `RUN_FINISHED` | 10 | 默认 | 结果渠道，普通 | 是 |
| `run_failed` | `RUN_FAILED` | 10 | 默认 | 结果渠道，高 | 是 |
| `approval` | `APPROVAL` | 10 | time-sensitive | 审批渠道，高 | 是 |
| `computer_approval` | `COMPUTER_APPROVAL` | 10 | time-sensitive | 审批渠道，高 | 否 |
| `vault_request` | `VAULT_REQUEST` | 10 | time-sensitive | 审批渠道，高 | 否 |
| `plan_confirm` | `PLAN_CONFIRM` | 10 | 默认 | 结果渠道，普通 | 否 |
| `info` | `INFO` | 5 | 默认 | 结果渠道，普通 | 否 |

- `APPROVAL` 通知上只能直接“拒绝”，批准要打开 App、过本机验证。`COMPUTER_APPROVAL` 批准和拒绝都要签名，通知上没有按钮。
- `vault_request`：agent 请用户往保险箱里填账号密码，运行等着（`thinktin://vault/request/{id}`）。
- `plan_confirm`：agent 建了或改了计划，等用户确认（`tt.plan`）。

## 3. 载荷

APNs：

```json
{
  "aps": {
    "alert": { "title": "…", "body": "…" },
    "sound": "default",
    "category": "VAULT_REQUEST",
    "thread-id": "<运行 id 或计划 id>",
    "interruption-level": "time-sensitive",
    "badge": 3
  },
  "tt": {
    "kind": "vault_request",
    "instance": "…", "run": "…", "approval": "…", "plan": "…", "inbox": "…",
    "vault_request": "…",
    "subtype": "…"
  }
}
```

- `tt` 里只有 id，没有的键不带。`inbox` 是这条通知在收件箱里的条目，点开后用 `inbox_item(id)` 取、`mark_inbox_read` 标已读。
- Android（FCM 的 `data`、极光的 `extras`）是同样的键加 `tt_` 前缀：`tt_kind`、`tt_instance`、`tt_run`、`tt_approval`、
  `tt_plan`、`tt_inbox`、`tt_vault_request`、`tt_subtype`。
- 正文是 agent 写的（运行摘要、工具调用的标题、保险箱请求的用途）带“AI 生成”标识（16.3），按用户的语言。命中内容过滤的
  换成中性提示，原文留在收件箱。
- 同一个运行的通知 `thread-id` 相同；审批、保险箱请求、计划待确认带 `apns-collapse-id`（Android 的 `collapse_key` /
  `tag`），状态变了新通知替换旧的。
- 推送里没有用户 id：退出登录、换账号时 App 清掉已送达的通知、角标设成 0。

## 4. 子类型

`tt.subtype`（Android 是 `tt_subtype`）和收件箱条目的 `subtype` 说是哪一种提醒，App 据此跳转、刷新，不用解析文字。
是字符串：以后会加新值，不认识的按 `kind` 显示。

| subtype | kind | 什么时候 | App 怎么做 |
| --- | --- | --- | --- |
| `account_frozen` | `info` | 账号被冻结 | 显示冻结页 |
| `account_restored` | `info` | 账号解冻 | 重查账号、重新订阅事件流、同步收件箱 |
| `stopped_all` | `info` | 点了“全部停止” | 刷新运行和计划 |
| `approval_skipped` | `info` | 审批超时、按策略跳过了这一步（带 `approval`） | 进运行详情 |
| `trigger_disabled` | `info` | 计划的触发规则失效、被停用（带 `plan`） | 进计划详情，让用户删掉重加 |
| `im_channel_disabled` | `info` | IM 群机器人失效、渠道被停用 | 进 IM 渠道设置 |
| `report_handled` | `info` | 内容举报处理完 | 进举报记录 |
| `invalid`、`no_balance`、`unavailable`、`rate_limited`、`overloaded`、`device_offline` | `run_failed` | 运行进入等待（和 `Run.wait_code` 一样） | 去换 key、充值、开电脑，或者等它自己继续 |

## 5. 有效期

- 设备离线时推送服务先存着，开机后送到；各家都只给一个应用留最后一条。没指定的存 24 小时（`notify::DEFAULT_TTL`）。
- 审批存到审批过期；保险箱请求存到请求过期（7 天，极光最多 3 天）。排队超过有效期的不发了，收件箱里照样有。
- 处理过的审批（别的设备上批了、过期了、运行结束了）不再推。

## 6. 角标和已读

- 角标是发的时候收件箱的未读数（排队期间读了的不算）：APNs 的 `aps.badge`，FCM 的 `notification_count`（支持角标的
  桌面显示）。极光要配 `badge_class` 才能设角标，还没接。App 在前台时用 `cached_unread()` 自己设。
- 审批处理完（批准、拒绝、超时、运行结束）、保险箱请求处理完（填了、拒绝了），收件箱里那条自动算已读。

## 7. 还没做的

- macOS App（P3）的 bundle id 不同，要按平台配 `apns-topic`。
- 极光的角标（`badge_class`）。

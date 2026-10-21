# IM 渠道（WBS 10.5）

> 用户把飞书 / Lark、企业微信、钉钉的群机器人绑到账号上，运行完成、需要审批、运行失败这些重要事件
> 除了系统推送和收件箱，也发到群里。只发通知；群里不能对话，也不能审批。

## 1. 用户怎么用

1. 在群里加一个“自定义机器人”（企业微信叫“消息推送”），复制 webhook 地址；飞书、钉钉建议开“加签”，把密钥也复制下来。
2. App 里新建 IM 渠道：粘贴地址（和密钥），选要发的事件（默认全部），起个名字。
3. 点“发测试消息”，群里收到一条就绑好了。发不出去的原因显示在渠道上（`last_error`）。

群机器人设了“自定义关键词”时，关键词填 `ThinkTin`：每条消息的标题都以它开头。

## 2. 接口

| 接口 | 说明 |
|---|---|
| `GET /v1/im-channels` | 渠道列表：平台、名字、`hint`（token 后 4 位）、有没有密钥、订阅的事件、开关、最近发送时间和错误。**没有地址和密钥** |
| `POST /v1/im-channels` | `{webhook_url, secret?, label?, events?}`，返回 201。平台按地址认（`feishu`、`lark`、`wecom`、`dingtalk`）；每人最多 20 个 |
| `PATCH /v1/im-channels/{id}` | 改 `label`、`events`、`enabled` |
| `PUT /v1/im-channels/{id}/webhook` | 换地址或密钥（`{webhook_url, secret?}`），要是同一家的；之前的错误清掉 |
| `POST /v1/im-channels/{id}/test` | 发测试消息，202；经出箱发，结果写回 `last_sent_at` / `last_error`。每人每小时 10 条（`[api.limits] im_tests_per_hour`） |
| `DELETE /v1/im-channels/{id}` | 删除 |

`events` 是 `run_finished`、`run_failed`、`approval` 中的若干个（至少一个；不想收就关掉渠道）。
增删改、换地址、测试都记审计，只记平台和 `hint`。客户端核心（11.x）有对应的方法（`im_channels`、`add_im_channel`……）。

## 3. 地址、凭证和防 SSRF

- 地址只认各家官方的固定前缀，后面只能跟 token（字母、数字、`-`、`_`，8 到 128 个字符），大小写、端口、用户名、
  多余的路径或参数都不认（`proto::im::parse_webhook`）：

  | 平台 | 前缀 |
  |---|---|
  | 飞书 | `https://open.feishu.cn/open-apis/bot/v2/hook/` |
  | Lark | `https://open.larksuite.com/open-apis/bot/v2/hook/` |
  | 企业微信 | `https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=` |
  | 钉钉 | `https://oapi.dingtalk.com/robot/send?access_token=` |

- 只存 token，发送时按前缀重新拼地址：库里的数据指不到别的主机。发送不跟随重定向，只走 https。
- token 和签名密钥一起用用户自己的 DEK 加密（AES-256-GCM），附加认证数据是单独的域 `thinktin/im/v1/` 加用户 id
  和渠道 id：挪到别的用户、别的渠道解不开，和模型 key、保险箱、产出物的密文不能互换（`keyvault::KeyVault::seal_webhook`）。
- 出箱条目里只有渠道 id 和消息，不带凭证；后台发送时才解开，用完清零。网络错误、日志里不出现地址（地址里有 token）。
- 注销账号时渠道一起删掉（DEK 也删了）。

## 4. 发送

- 通知写收件箱的同一个事务里，给订了这个事件、开着的每个渠道各写一条出箱条目（去重键 `im:<渠道>:<收件箱条目>`），
  各自重试、各自限流。重试可能让群里收到重复的一条（各家的 webhook 都没有幂等键）。
- 和系统推送一样：先过内容过滤（命中的换成中性提示，原文留在收件箱），过期的不发，审批已经处理了的不发；
  agent 生成的正文带“AI 生成”标识；按用户的语言。
- 消息格式：飞书 / Lark 发富文本（`post`）的纯文本节点（`text` 消息会解析 `<at user_id="all">`，agent 写的摘要不能
  @ 所有人）；企业微信、钉钉发纯文本，不填 @ 的名单。正文最多 1800 字节。
- 签名在发送时算（各家都要求时间戳在一小时内，重试可能隔很久）：
  - 飞书 / Lark：`sign = base64(HMAC-SHA256(key = "<秒级时间戳>\n<密钥>", 消息为空))`，和 `timestamp` 一起放请求体；
  - 钉钉：`sign = urlencode(base64(HMAC-SHA256(key = 密钥, "<毫秒级时间戳>\n<密钥>")))`，和 `timestamp` 一起放地址参数。
  测试里的签名向量用 Python 的 `hmac` 独立算出（`crates/notify/src/im/tests.rs`）。
- 限流：每个渠道每分钟的名额记在库里（多个后台副本共用）：飞书 / Lark 60 条（官方上限 100 条、每秒 5 条），
  企业微信、钉钉 18 条（官方 20 条，钉钉超了会被限 10 分钟）。名额满了推到下一分钟，不算一次尝试。
- 结果（各家多数错误是 HTTP 200 加错误码，按响应体判断；原因是我们自己写的，带厂商的错误码，不照抄对方的
  `errmsg`：企业微信的会带上调用方 IP）：

  | 情况 | 处理 |
  |---|---|
  | 机器人删了、被移出群、地址失效（飞书 19001；企业微信 93000、93004、93008、93019；钉钉 300001、300005、400101、400102、400106、400013） | 停用渠道，记下原因，收件箱和推送告诉用户一次 |
  | 签名不对、时间戳超时、关键词不匹配、IP 不在白名单（飞书 19021、19022、19024；钉钉 310000），内容被拒 | 记下原因，不重试，渠道照开（用户改好设置或换地址就行） |
  | 限流（飞书 11232；企业微信 45009、45033；钉钉 410100、130101）、服务端错误、网络错误 | 过一阵再试（钉钉等 10 分钟），最多 8 次 |

- 指标：`thinktin_im_total{result=delivered|dropped|retried|deferred}`。
- 关掉：`[push.im] enabled = false`（默认开）。关掉后用户照样能绑定，后台不发（出箱里的 IM 条目直接放弃）。

各家文档 2026-10-21 核对：飞书 `open.feishu.cn/document/client-docs/bot-v3/add-custom-bot`、Lark 同名页面，
企业微信 `developer.work.weixin.qq.com/document/path/91770`、全局错误码 `path/90313`，
钉钉 `open.dingtalk.com/document/orgapp/customize-robot-security-settings`、`custom-bot-send-message-type`。

## 5. 测试

| 测试 | 位置 |
|---|---|
| 地址只认官方前缀和 token；签名密钥按平台检查 | `crates/proto/src/im.rs` |
| 凭证的密文只在自己的域里解得开 | `crates/keyvault`（`webhook_secrets_roundtrip_and_stay_in_their_domain`） |
| 表的隔离、限流窗口、按读到的那一刻记结果、推后不算尝试 | `crates/store/src/tests.rs`（`im_channels_are_per_user_rate_limited_…`） |
| 三家的消息格式、签名（假的厂商服务验签）、错误码分类、不跟随重定向、错误里没有 token | `crates/notify/src/im/tests.rs` |
| 按订阅的事件进出箱、标题和标识、失效停用并通知、设置错误记原因、限流推后、过滤、删除和注销后放弃 | `crates/orchestrator/tests/im.rs` |
| 接口：增删改、换地址、测试消息、拒收的地址、审计不含凭证、测试消息限流、跨用户 404 | `crates/gateway/tests/api.rs`（`im_channels_over_http` 等） |

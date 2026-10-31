# 设备中继（WBS 14.1）

用户的电脑（macOS App 的后台守护进程、Windows 的托盘应用）主动连出到设备中继，保持一条 wss 长连接，电脑上不开入站端口
（架构方案第 7 节）。平台经它做两件事：

- **用电脑上的工具**：agent 调“我的电脑”的工具时，平台写一个调用，连着这台电脑的中继转过去，电脑回结果。
- **转发手机和电脑之间的消息**：配对应答和确认、高危操作的审批请求和决定、能力令牌、吊销
  （内容和签名见 [配对与验签协议](pairing.md)）。平台只转发，内容由两端签名，改不了也冒充不了；
  收件方不在线时排队，上线后投递。

## 1. 组成

| 部分 | 位置 | 做什么 |
|---|---|---|
| 中继服务 `thinktin-relay` | `crates/relay` | 接电脑的长连接；在线状态、心跳、离线检测；转调用、收结果；投递和收下消息 |
| 平台一侧 | `crates/orchestrator/src/computer.rs`（`DeviceCalls`） | 按会话绑定找用户在线的电脑，写调用，等结果 |
| 手机一侧 | `crates/gateway/src/routes/device_messages.rs`、client-core | 发消息给电脑、收电脑发来的消息、看电脑在不在线 |
| 连接协议 | `crates/proto/src/relay.rs` | 电脑和中继之间的帧 |
| 数据 | 迁移 `0014_device_relay.sql`、`crates/store/src/device_relay.rs` | 在线状态、调用、消息；中继自己的数据库角色 |

中继和控制面分开部署（维持大量长连接，扩容方式不同），可以多副本。副本之间不直接通信：
在线状态和要转给电脑的东西都在数据库里，平台写库并发通知（`thinktin_device`，载荷是设备 id），
连着那台电脑的副本收到通知去库里取。所以通知丢了、重复了都不影响正确性，监听断过就叫醒所有连接各自对一遍。

## 2. 连接

电脑 `GET /v1/connect` 升级成 WebSocket，请求头带 `Authorization: Bearer <访问令牌>`——就是这台电脑
登录账号时拿到的设备会话的令牌。中继验签（控制面签令牌用的公钥）、核对会话没吊销、账号没冻结、
设备是这个用户没下线的电脑（只接受 macOS、Windows 设备）。连不上时返回和接口一样的错误体：

| 状态 | `code` | 电脑怎么办 |
|---|---|---|
| 401 | `unauthenticated` | 刷新令牌后重连 |
| 401 | `session_revoked` | 被远程下线或注销了：回到登录页 |
| 403 | `account_frozen` | 账号被冻结：提示联系客服，不重连 |
| 403 | `forbidden` | 不是电脑 |
| 503 | `unavailable` | 中继停机中或连接数满了：退避后重连 |

一台电脑同时只保留最新的一个连接：又连了一次（比如开了两个进程），旧连接以 4009 关闭。

连上以后两边发 JSON 文本帧，`type` 字段区分种类：

| 方向 | `type` | 内容 |
|---|---|---|
| 中继 → 电脑 | `welcome` | 电脑的设备 id、心跳间隔 |
| 中继 → 电脑 | `call` | 工具调用：`id`、`tool`、`arguments`、发起的运行、`expires_at`（过了平台就不等了） |
| 中继 → 电脑 | `message` | 手机发来的消息，处理完回 `ack` |
| 中继 → 电脑 | `sent` / `error` | `send` 存下了 / 某一帧没处理成（`invalid`、`not_found`、`too_large`、`unavailable`、`internal`），带回 `ref`，连接不断 |
| 电脑 → 中继 | `hello` | 现在能用的工具（随系统权限变化，变了再发）、App 版本 |
| 电脑 → 中继 | `auth` | 换上新的访问令牌（同一个用户的同一台电脑） |
| 电脑 → 中继 | `result` | 调用的结果：MCP 的 `content` 数组、`is_error` |
| 电脑 → 中继 | `ack` | 收下了这条消息 |
| 电脑 → 中继 | `send` | 发给手机的消息（配对确认、审批请求），可以带 `ref` |

关闭码：4001 令牌过期或会话被吊销（刷新令牌后重连）、4003 账号被冻结（不重连）、4009 被同一台电脑的新连接顶掉
（不自动重连，避免两个进程互相顶）、1008 协议错误、1012 中继重启（马上重连，会连到别的副本）、1001 心跳超时。

大小上限：一帧 16 MiB；调用参数 4 MiB；结果 12 MiB（更大的换成一个错误交给 agent）；消息正文 64 KiB；
工具最多 256 个。

## 3. 心跳、令牌和离线

- 中继每隔心跳间隔（默认 20 秒）ping 电脑、刷新在线状态、核对会话。三个周期内没收到电脑的任何帧（含 pong）
  就断开、标记离线。电脑那边三个周期没收到 ping 也应该重连。
- 在线状态（`device_links`）记着电脑连在哪个副本的哪次连接上。中继挂了没人刷新，过 90 秒（`store::LINK_FRESH`）
  平台就当它离线，所以心跳间隔必须明显短于 90 秒（命令行限制在 30 秒以内）。
- 会话被吊销（手机上把电脑远程下线、退出登录）在下一次心跳时以 4001 断开；账号冻结以 4003 断开；
  数据库一时不通时这一轮不踢人。
- 访问令牌 15 分钟过期。电脑在过期前发 `auth` 换上新令牌（刷新流程和手机一样，client-core 已有），
  否则到期时以 4001 断开，电脑刷新后重连。
- 电脑连上时唤醒在“等待电脑上线”（7.11）的运行，它们马上能接着跑。

## 4. 工具调用：按会话绑定路由

目标电脑只由运行的归属决定：运行 → 实例 → 用户 → 这个用户自己的、没下线、在线的电脑（几台都在线时取最近连上的）。
agent 的输出里写什么设备都没用（架构方案第 6 节“路由目标只由会话绑定决定”）。

`DeviceCalls::call(user, run, tool, arguments, timeout)` 的结果：

| 结果 | 说明 |
|---|---|
| `Ok(CallOutput)` | 电脑回的 MCP 内容；工具自己报错时 `is_error` 为真 |
| `NoComputer` | 这个账号没有登录着的电脑：提示用户在电脑上装 App、登录 |
| `Offline` | 有电脑但不在线：执行器把运行转入“等待电脑上线”（7.11），电脑连上中继时唤醒 |
| `Unsupported` | 电脑报上来的工具里没有它（比如没给屏幕录制权限） |
| `Timeout` | 到时间没回：调用标成过期，中继不再转出，晚到的结果不收 |
| `Failed` | 转出去以后电脑断线了：马上判失败，不重发（工具可能有副作用） |

等结果靠数据库通知（`thinktin_device_call`），通知丢了每 2 秒去库里看一次。

## 5. 消息

- 方向是定的：配对确认、审批请求只能电脑发给手机；配对应答、审批决定、能力令牌、吊销只能手机发给电脑。
  两台设备都得是同一个用户没下线的设备。
- 排队 24 小时，过期没送到的丢掉（审批请求本身最长 24 小时有效）。
- 电脑一侧：中继投递 `message`，电脑回 `ack` 后不再投；没回的下次连上再投一次，电脑按消息 id 去重。
- 手机一侧（接入网关）：`POST /v1/devices/{id}/messages` 发（`{"kind", "body"}`），
  `GET /v1/devices/current/messages` 收，`POST /v1/devices/current/messages/ack`（`{"ids": [...]}`）确认。
  `GET /v1/devices` 里电脑带 `online`。client-core 对应 `send_device_message`、`device_messages`、
  `ack_device_messages`、`devices`。

## 6. 数据和权限

- `device_links`（在线状态）、`device_calls`（调用，参数和结果里可能有文件内容、截图）、`device_messages`（消息）。
  业务接口只能看自己电脑的在线状态、收发自己设备的消息（RLS）；调用只有后台和中继碰得到。
- 中继用自己的数据库角色 `thinktin_relay`：只能读会话、设备、账号状态里核对用的几列，维护在线状态，
  领取和回填调用，收发消息，唤醒等电脑的运行；读不到运行内容、key、手机号。
- 调用和消息建了 24 小时后由控制面的数据维护删掉；注销账号时一起删（16.4）。

## 7. 部署

```sh
thinktin-relay \
  --listen 0.0.0.0:8792 \
  --database-url "$DATABASE_URL" \             # 登录账号要有 thinktin_relay 的成员身份
  --access-key "a1=<公钥>" \                    # thinktin-server check-config 打印的 access token key
  --node "$HOSTNAME" --metrics-listen 0.0.0.0:9792
```

- 数据库：`GRANT thinktin_relay TO <中继的登录账号>;`（迁移由控制面执行）。
- 访问令牌公钥：`thinktin-server check-config` 打印 `access token key = a1=...`；轮换签名密钥时新旧都给
  （`--access-key` 可重复，或环境变量 `THINKTIN_ACCESS_TOKEN_KEYS` 用逗号分隔）。
- TLS 在负载均衡上终结（443），负载均衡对 WebSocket 的空闲超时要比心跳间隔长；就绪检查 `GET /readyz`
  （停机中或数据库不通时 503），存活检查 `GET /healthz`。
- 停机（SIGTERM）：不再接新连接，电脑连接以 1012 关闭（它们马上重连到别的副本）、去掉在线状态，最多等 `--grace-secs`。
- 指标：`thinktin_relay_connections`、`thinktin_relay_calls_total{outcome}`、`thinktin_relay_messages_total{direction}`、
  `thinktin_relay_disconnects_total{reason}`。

## 8. 还没做的

- ~~电脑端的工具服务、执行器接上电脑工具（14.2）~~：已做，见 [电脑工具](desktop.md)。
- 电脑发来的审批请求推送到手机（做审批界面 12.9 / 14.8 时加）；现在手机 App 进前台时拉
  `GET /v1/devices/current/messages`。
- client-core 的 FFI（给 App 用）随 12.9 / 14.8 加。

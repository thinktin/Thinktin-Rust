# ThinkTin 模型网关与密钥库

> 更新日期：2026-10-16　｜　对应 WBS：9.1 信封加密、4.4 沙箱令牌、9.2 鉴权与路由、9.3 流式透传、9.4 计量、9.5 限额与熔断、9.6 SSRF 防护、9.7 厂商适配、9.12 主流模型品牌预置（适配表已按官方文档核对，待真实 key 联调）
>
> 依据《ThinkTin 平台架构方案 v3》第 5 节和 4.6 节。

## 1. 状态

模型网关（`crates/llm-gw`）、密钥库（`crates/keyvault`）和沙箱令牌（`crates/auth` 的 `sandbox_token`）都已实现，并用真实 agent 跑通了整条链路：

```
agent（沙箱内） ──沙箱令牌──▶ llm-gw ──用户 key──▶ 厂商
      ▲                      │ 校验令牌、按别名路由、换 key
      └──── 原样流式返回 ◀────┘ 同时记录用量
```

| Agent | 协议 | 经网关实测 |
|---|---|---|
| Claude（`acp` 和 `cli` 两种接入） | Anthropic Messages（带 `?beta=true`） | 通过，含工具调用和审批（两次模型请求） |
| Codex | OpenAI Responses | 通过 |
| Pi | Chat Completions | 通过 |
| OpenClaw | Chat Completions | 通过 |
| Hermes | Chat Completions | 通过 |

每次实测都检查：厂商收到的每个请求都带用户 key、从没见过沙箱令牌；agent 用的别名被换成了上游模型；每次调用都记了用量（`GW=1 tools/smoke/smoke.sh <agent>`，见第 9 节）。

常驻模式下的取消也经网关实测过（`GW=1 tools/smoke/serve_check.py <agent>`，六种组合都通过）：agent 中途取消后，网关把那次调用记成 `client_closed`，并断开和厂商的连接；下一轮照常。

## 2. 密钥库（9.1）

- **信封加密**：每个用户一把 32 字节数据密钥（DEK），由 KMS 主密钥加密后存库。用户的 API key 用 DEK 做 AES-256-GCM 加密，随机数 12 字节放在密文前面。
- **AAD 绑定**：DEK 的 AAD 是 `thinktin/dek/<主密钥 id>/<用户 id>`；API key 的 AAD 是带长度前缀的“用户 id + 记录 id”。密文挪到别的用户或别的记录下都解不开。
- **只显示后 4 位**：`SealedSecret.last4` 只存后 4 位；key 短于 12 个字符时显示 `****`。
- **DEK 缓存**：解开的 DEK 在内存里缓存 5 分钟（可调），用 `Zeroizing` 包装。解开的 API key 用 `SecretString` 包装，一次请求用完就丢，不缓存。
- **注销即销毁**：`destroy_user_key` 删掉 DEK 并清缓存，该用户的所有密文从此无法解开。
- **KMS**：`Kms` trait，现有本地实现 `LocalKms`（开发用，主密钥从环境变量读）。云 KMS 适配随 2.6 接入。

## 3. 沙箱令牌（4.4）

格式 `tts1.<kid>.<base64url(claims)>.<base64url(Ed25519 签名)>`，签名覆盖前三段，校验用 `verify_strict`。控制面持私钥签发，网关只持公钥，按 `kid` 支持多把公钥并存（轮换）。

| 字段 | 含义 | 网关怎么核对 |
|---|---|---|
| `iid` | 实例 | 实例存在、启用 |
| `uid` | 用户 | 等于实例的所属用户 |
| `grant` | 运行授权 | 没被吊销 |
| `sbx` | 沙箱 id，每次唤醒都变 | 等于实例当前的沙箱 id，旧沙箱的令牌立即失效 |
| `net` | 沙箱的来源地址 | 等于请求的来源地址（IPv4 映射的 IPv6 按 IPv4 比较）；为空的令牌默认拒绝 |
| `iat`、`exp` | 签发、过期时间 | 允许 30 秒时钟偏差；有效期最长 7 天 |
| `jti` | 令牌 id | 只用于审计和用量记录 |

令牌可以放在 `Authorization: Bearer`、`x-api-key` 或 `api-key` 头里（各家 SDK 用法不同）。所有校验失败对 agent 都只返回“sandbox token rejected”，具体原因只写日志。

## 4. 接口（9.2、9.3）

| 路径 | 转发到厂商的 | 说明 |
|---|---|---|
| `POST /anthropic/v1/messages` | `<anthropic_base>/v1/messages` | 只放行查询参数 `beta=true` |
| `POST /anthropic/v1/messages/count_tokens` | `<anthropic_base>/v1/messages/count_tokens` | 不计量 |
| `POST /openai/v1/chat/completions` | `<openai_base>/chat/completions` | |
| `POST /openai/v1/responses` | `<openai_base>/responses` | 厂商不提供时返回 400 |
| `GET /anthropic/v1/models[/{id}]`、`GET /openai/v1/models[/{id}]` | 不转发 | 只列实例配置的别名 |
| `GET /healthz` | | |

**路由**：令牌 → 实例 → 请求体里的 `model`（别名）→ 凭证 + 上游模型。凭证必须属于实例的用户且没被停用。

**请求体只改两处**：顶层 `model` 换成上游模型；Chat Completions 流式请求没开 `stream_options.include_usage` 时替 agent 打开（第 6 节）。其余字段按原始字节、原顺序转发。

**网关和厂商必须读出同一个请求**，所以下面几种直接 400：
- 顶层键重复，**按不区分大小写比较**（Go 写的中转服务按不区分大小写匹配字段，`MODEL` 会覆盖 `model`）；
- `model`、`stream`、`stream_options`、`background` 不是标准写法（比如 `Stream`）；
- 顶层键超过 256 个；`model` 超过 1 KB、`stream_options` 超过 4 KB；
- Responses 请求带 `background: true`（后台模式立即返回、用量为空，厂商在后台继续生成并计费，网关记不上账）。

这几个字段只按长度和字面值检查，不把 agent 给的大值整个解析成 `Value`。

**请求头白名单**：Anthropic 协议只转发 `anthropic-version`（缺省补 `2023-06-01`）、`anthropic-beta`、`accept`、`user-agent`；OpenAI 协议只转发 `openai-beta`、`accept`、`user-agent`。agent 带的鉴权头、Cookie 等一律丢掉，换成用户 key：OpenAI 协议用 `Authorization: Bearer`，Anthropic 协议按厂商表用 `x-api-key`、`Bearer` 或两者都带。

**响应**：状态码和响应体原样流回；响应头只回 `content-type`、`retry-after`、`request-id`、`x-request-id`、`anthropic-ratelimit-*`、`x-ratelimit-*`。厂商返回非 2xx 时读完错误体（最多 1 MiB、30 秒），把其中出现的用户 key 抹成 `[redacted]` 再返回：多读 key 长度个字节保证跨过上限的 key 也能整体抹掉；截断或中途断开时去掉结尾残留的半截 key。

**错误格式**：网关自己产生的错误按协议给出（Anthropic 的 `{"type":"error","error":{...}}`，OpenAI 的 `{"error":{...}}`），agent 能正常显示。

| 情况 | 状态码 |
|---|---|
| 令牌缺失或无效 | 401 |
| 别名没配置 | 404 |
| 请求体不合法、厂商不支持该协议 | 400 |
| 凭证不可用 | 403 |
| 请求体超过上限（默认 32 MiB） | 413 |
| 60 秒内没收完请求体 | 408 |
| 速率、并发超限，熔断 | 429，带 `Retry-After` |
| key 的当日预算用完 | 402（不用 429，免得 agent 反复重试） |
| 上游地址被 SSRF 防护拦截、连不上 | 502 |
| 上游超时 | 504 |

### 抹掉保险箱里的值（9.11）

转发前把用户密码保险箱里的值从请求体里抹掉，换成 `[vault:名字]`，模型永远看不到明文。逐个 JSON 字符串解码后比较
（认得各种转义写法），改过的字符串按标准写法编码回去，其余字节原样转发；`model`、`stream` 这几个网关要读的键不动。
解开的值按用户缓存 5 秒，读不到保险箱就不转发（502）。详见[密码保险箱](vault.md)第 4 节。

## 5. 数据模型

网关通过 `Directory` trait 读路由数据。生产环境（`serve --database-url`）直接读控制面的 Postgres（`thinktin_llmgw` 角色：只读路由相关的表、写用量表），实例、凭证、授权状态短时缓存（`--cache-secs`，默认 5 秒，吊销和改路由最多这么久后生效）；令牌里的沙箱和缓存对不上时重读一次，实例刚唤醒换了沙箱也不会误拒。用户的包裹 DEK 和凭证一起读出，用同一把 KMS 主密钥（`THINKTIN_KMS_KEY`）解开。开发用 JSON 文件（`DevStore`，`serve --store`）。

```jsonc
{
  "kms_key_id": "dev",
  "user_keys": { "user-1": { "kms_key_id": "dev", "ciphertext": [/* 包裹后的 DEK */] } },
  "credentials": [{
    "id": "cred-1", "user_id": "user-1", "vendor": "deepseek",   // 或 "custom"，此时用下面三项
    "anthropic_base": null, "openai_base": null, "responses": false,
    "secret": { "ciphertext": [/* 随机数 + 密文 */], "last4": "a1b2" },
    "daily_token_limit": 2000000, "disabled": false
  }],
  "instances": [{
    "id": "inst-1", "user_id": "user-1", "sandbox": "sbx-1", "active": true,
    "routes": { "main": { "credential": "cred-1", "model": "deepseek-chat",
                          "fallbacks": [{ "credential": "cred-2", "model": "qwen3.8-flash" }] } },
    "limits": { "requests_per_minute": 120, "max_concurrent": 8 }
  }],
  "revoked_grants": []
}
```

## 6. 计量（9.4）

| 协议 | 用量从哪来 |
|---|---|
| Anthropic Messages | 流式：`message_start` 的 `message.usage`，`message_delta` 的累计值覆盖；非流式：响应体 `usage` |
| Chat Completions | 带 `usage` 的分片（取最后一个）；非流式：响应体 `usage`。缓存命中取 `prompt_tokens_details.cached_tokens`，DeepSeek 取 `prompt_cache_hit_tokens` |
| Responses | `response.completed`、`response.incomplete`、`response.failed` 事件里的 `response.usage`；非流式：响应体 `usage` |

- 统一成四个数：未命中缓存的输入、缓存命中、缓存写入、输出。预算按四者之和记账。
- **补 `include_usage`**：Chat Completions 流式请求没开时网关替 agent 打开（这是透传原则唯一的例外），并在转发时去掉厂商多发的那个“`choices` 为空、只带 `usage`”的分片，agent 看到的流和没开时一样。厂商表里 `chat_stream_usage = false` 的厂商不补。
- 计量记录（`UsageRecord`）含时间、实例、用户、运行授权、沙箱、令牌 id、别名、凭证、厂商、上游模型、接口、是否流式、状态码、结果、厂商报告的用量、记账的 token 数（`charged_tokens`）、是否估算（`estimated`）、耗时，**不含请求和响应内容**。现在以结构化日志输出（target `llm_gw::usage`），用量表随 9.10 接入。
- **结果**：`complete`（读完）、`client_closed`（agent 中途断开，包括还没等到厂商响应头就断开）、`upstream_error`（上游中途出错或超时）、`connect_failed`（请求没发出去）、`upstream_status`（上游返回非 2xx）。请求一旦可能到了厂商，不管怎么结束都会记一条。
- **取不到用量就按保守估算记账，宁可多记不能漏记**：输入按请求体字节数 / 4，输出按请求里的最大输出 token 数（`max_tokens`、`max_completion_tokens`、`max_output_tokens`，都没有按 8192）；已经流出事件的，输出按每个事件 4 个 token 估（不超过最大输出）。中途断开时已知的输出数可能还没更新，取估算和已知的较大值。厂商返回非 2xx、请求没发出去，不记账。
- 解析只取 `type`、`usage`、`message.usage`、`response.usage`、`choices[0].usage` 这几个字段，其余内容跳过、不解析成 `Value`，厂商发再大的内容也不会放大内存。SSE 解析是增量的，任意切分都能正确处理；单个事件超过 8 MiB 就跳过这个事件（照常转发），后面的事件照常取用量；非流式响应体超过 16 MiB 就按估算记账。

## 7. 限额与熔断（9.5）

- **按实例限速**：令牌桶，容量和每分钟补充量都是 `requests_per_minute`（默认 120）。
- **按实例限并发**：`max_concurrent`（默认 8），许可一直持有到响应流结束。
- **熔断**：一分钟内被限速拒绝的次数达到每分钟配额（agent 无视 429 在猛打，比如死循环），就熔断 5 分钟，并输出 `llm_gw::breaker` 告警日志，供控制面通知用户。
- **按 key 每日预算**：`daily_token_limit`，按东八区切天（`--budget-utc-offset-hours` 可调）。建 key 时给，之后用
  `PATCH /v1/credentials/{id}` 改（`null` 取消上限，client-core 的 `set_credential_daily_limit`），网关在缓存过期
  （`--cache-secs`，默认 5 秒）后用上新的；放宽或取消时等 key 的运行接着跑。请求前检查、响应后记账，所以同时在途的请求可能让当天用量略微超出上限。生产环境的账本以用量表的汇总为准（多副本共享），加上本副本还没落库的记账；开发环境在内存里。用量记录进队列、后台批量写用量表，库不可用时退回结构化日志，不丢账。

### 降级链（9.9）

每个别名除了主 key，还可以按顺序配最多 3 个备用项（key + 那边的上游模型），表 `model_route_fallbacks`，接口是 `PUT /v1/instances/{id}/routes` 里每个别名的 `fallbacks`。网关按顺序试，在把任何内容交给 agent 之前决定换不换：

| 情况 | 换下一个 | 这把 key 冷却 |
|---|---|---|
| 401、402、403（key 失效、欠费、没权限） | 换 | 5 分钟 |
| 429、503、529（被限流、过载） | 换 | 按厂商的 `Retry-After`（1 秒到 5 分钟），没给就 30 秒 |
| 连不上（请求没发出去） | 换 | 30 秒 |
| key 停用、当日预算用完、不支持这个协议、地址被 SSRF 规则拦下 | 跳过，不发请求 | — |
| 其他错误（400 之类请求本身的问题） | 不换，原样交给 agent | — |
| 超时、读响应中途出错 | 不换：厂商可能已经在处理并计费，换 key 重发会重复扣钱 | — |

- 冷却是每个副本各自在内存里记的，只调整顺序（冷却中的排到最后），从不拒绝请求；成功一次就解除。所以只有一把 key 的别名行为和以前完全一样。
- 每次发出去的尝试各记一条用量：别名不变，key、厂商、上游模型按实际的记。失败的尝试记 `upstream_status` 或 `connect_failed`，不记账。
- 都失败时：有厂商的真实失败就把最后一个原样交给 agent（照样抹掉 key）；一个都没发出去就报主 key 的原因（比如 402 预算用完）。
- 删除 key 时，被任何没删除的实例的别名（主路由或降级链）用着都拒绝；删除实例时它的别名和降级链一起删掉。
- 保存别名时，新引用的 key 必须是自己的、没删除、没停用；实例原来就用着的停用 key 可以留着（网关照样跳过它），所以从别名里去掉别的 key 不会因为它保存不了。

### 没有能用的 key（7.11）

降级链里一把 key 都没用上、请求没发出去（都停用了、当日预算用完、解不开、地址被拦）时，也记一条用量，
结果是 `unavailable`、状态码是回给 agent 的那个（402、403……），不计费。执行器按这次尝试以来的调用结果判断
agent 是不是卡在 key 上：要用户处理的失败（401、403、402、`unavailable`）连续两次，或者限流、繁忙（429、503、529、
连不上）持续两分钟以上；agent 这一轮刚结束时条件放宽。卡住就停下这一轮、运行转入“等待额度 / key”，见架构方案 4.7。

### 入站连接

网关自己接受连接（axum 自带的 `serve` 不装计时器，hyper 的请求头超时不生效）：读完一个请求头（包括长连接上等下一个请求）限 30 秒，同时最多 8192 个连接，每个来源地址最多 64 个（`--max-connections-per-ip`），请求体限 60 秒收完。慢速连接占不住资源。

## 8. SSRF 防护（9.6）

用户可以给自定义端点填 base URL，网关替用户发请求，所以：

被拦截时，返回给 agent 的消息不说明是“解析不到”还是“解析到内网”（否则可以拿来探测内网域名是否存在），具体原因只写日志。

1. **静态检查**：只允许 https；URL 不能带用户名密码、查询串、片段；主机是 IP 字面量时直接检查（URL 解析器会把 `0x7f.1`、`2130706433` 这类写法规范化，绕不过去）。
2. **解析时检查**：访问厂商的 HTTP 客户端装了只返回公网地址的 DNS 解析器，任何一个解析结果不是公网地址就整体拒绝。检查过的地址就是实际连接的地址，没有“检查一次、连接时再解析一次”的 DNS 重绑定窗口。
3. **不跟随重定向**。
4. **出口代理**：配了 `--egress-proxy` 时域名由代理解析，网关只做一次预检，最终要靠代理自己的策略兜底（架构方案要求网关出网走专用出口代理）。

拦截的地址：IPv4 的本网络、私网、回环、运营商级 NAT（含阿里云元数据 100.100.100.200）、链路本地（含 169.254.169.254 等云元数据）、文档和基准测试网段、组播和保留地址；IPv6 只放行全球单播 `2000::/3`，再排除 Teredo、6to4、文档网段，IPv4 映射和 NAT64 地址按内嵌的 IPv4 判断。

## 9. 本地运行

```bash
cargo build -p llm-gw
export THINKTIN_DEV_KMS_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')   # 本地 KMS 主密钥
target/debug/llm-gw keygen --kid dev          # 打印 THINKTIN_DEV_TOKEN_SEED=... 和 --token-key dev=...
export THINKTIN_DEV_TOKEN_SEED=...

# 保存一把 key（从标准输入读，不进命令行参数），再手动在 dev.json 里加实例和别名
printf %s "$DEEPSEEK_KEY" | target/debug/llm-gw put-key --store dev.json --id cred-1 --user user-1 --vendor deepseek

target/debug/llm-gw serve --store dev.json --token-key dev=...
target/debug/llm-gw issue-token --instance inst-1 --user user-1 --sandbox sbx-1 --net 127.0.0.1
target/debug/llm-gw vendors                   # 厂商适配表

# 真实 agent 走网关的端到端测试：agent → agent-shim → llm-gw → 扮演厂商的替身
GW=1 tools/smoke/smoke.sh claude
GW=1 PROMPT='MOCK_TOOL:Bash:{"command": "touch x", "description": "touch"}' EXPECT=MOCK_DONE \
  tools/smoke/smoke.sh claude --harness cli --allow-tools execute
```

`--insecure-upstreams`（允许 http 和非公网上游）和 `--allow-unbound-tokens`（接受不绑定来源地址的令牌）只用于本地开发。

## 10. 已知问题与后续工作

| 问题 | 影响 | 后续 |
|---|---|---|
| 来源地址按 TCP 对端地址核对 | 网关前面如果有做 SNAT 的负载均衡，对端地址会变成负载均衡的地址 | 部署时让沙箱直连网关，或增加可信代理配置 |
| 预算请求前检查、响应后记账 | 同时在途的请求、多副本之间的汇总间隔可能让当天用量略微超出上限 | 必要时预扣 |
| 取不到用量时按估算记账 | 估算偏保守：请求里有 base64 图片时输入会估得很高；取消的流按事件数估输出 | 可接受（只影响预算，不影响厂商实际扣费）；对账以厂商账单为准 |
| 只有 Chat Completions 接口的厂商不能给 Codex 用 | Codex 只会 Responses 协议 | 网关做协议转换（架构方案 5.3，后期） |
| 降级链换到不同的上游模型 | Claude（Opus 5.5 起）的思考块绑定模型和会话，Gemini 有思考签名，同一会话中途换模型会被厂商拒绝 | 降级链对这类模型只在同一上游模型的不同 key 之间切换，或换模型时去掉历史思考块（后续） |
| 厂商适配表只按文档核对，还没用真实 key 联调 | 文档没写清的地方（见第 11 节“待联调”）可能和实际不符 | 9.7 用各家真实 key 逐项验证 |
| 路由数据、预算账本、用量记录都在内存或日志里 | 只适合开发 | 3.x 数据层、9.10 用量看板 |

## 11. 厂商适配表（9.7、9.12）

`llm-gw vendors` 打印完整的表。表在 `crates/proto/src/vendors.rs`，模型网关按它路由，接入网关按它校验 key，App 通过 `GET /v1/vendors` 拿到可选厂商（client-core 的 `vendors()`），每家带着 `subscription_key_prefixes`、`plan_only_bases`（11.9），保存前可以先在本地提示，服务端照样检查。只预置模型品牌方自己的官方接口；聚合平台、中转站不预置，用户按自定义端点（`custom`）填地址。**各家的国内站和国际站账号、key 互不相通**，用错区域的地址会返回 401，所以每个区域单独一条，用户保存 key 时选区域。

前 5 家（9.7）按官方文档核对于 2026-10-14，后 9 家（9.12）核对于 2026-10-16。

| id | Anthropic 兼容（不带 /v1） | 鉴权头 | OpenAI 兼容 | Responses 前缀 | Chat 流式用量 |
|---|---|---|---|---|---|
| `deepseek` | `https://api.deepseek.com/anthropic` | x-api-key | `https://api.deepseek.com` | 同左 | 最后一个内容分片自带，不用补 |
| `qwen-cn` | `https://dashscope.aliyuncs.com/apps/anthropic` | x-api-key | `https://dashscope.aliyuncs.com/compatible-mode/v1` | 同左 | 补 `include_usage` |
| `qwen-intl` / `qwen-us` / `qwen-hk` | `dashscope-intl` / `dashscope-us` / `cn-hongkong.dashscope` 同路径 | x-api-key | 同路径 | 同左 | 补 |
| `glm-cn` | `https://open.bigmodel.cn/api/anthropic` | x-api-key | `https://open.bigmodel.cn/api/paas/v4` | `https://open.bigmodel.cn/api/v1` | 最后一个分片自带，文档没有 `stream_options` |
| `glm-intl`（Z.ai） | `https://api.z.ai/api/anthropic` | x-api-key | `https://api.z.ai/api/paas/v4` | `https://api.z.ai/api/v1` | 同上 |
| `kimi-cn` | `https://api.moonshot.cn/anthropic` | Bearer | `https://api.moonshot.cn/v1` | 同左（只支持 kimi-k3） | 补；有时在 `choices[0].usage` |
| `kimi-intl` | `https://api.moonshot.ai/anthropic` | Bearer | `https://api.moonshot.ai/v1` | 同左 | 同上 |
| `minimax-cn` | `https://api.minimax.cn/anthropic` | Bearer | `https://api.minimax.cn/v1` | 同左 | 补 |
| `minimax-intl` | `https://api.minimax.io/anthropic` | Bearer | `https://api.minimax.io/v1` | 同左 | 补 |
| `anthropic` | `https://api.anthropic.com` | x-api-key | `https://api.anthropic.com/v1`（兼容层，官方定位测试用） | 无 | 补 |
| `openai` | 无 | | `https://api.openai.com/v1` | 同左（有状态） | 补 |
| `gemini`（Gemini API） | 无 | | `https://generativelanguage.googleapis.com/v1beta/openai` | 无 | 补 |
| `xai` | 无 | | `https://api.x.ai/v1`（官方标为旧接口） | 同左 | 每个分片都带累计值，不用补 |
| `mistral` | 无 | | `https://api.mistral.ai/v1` | 无 | 不补：接口文档没有 `stream_options` |
| `doubao-cn`（火山方舟） | `https://ark.cn-beijing.volces.com/api/compatible` | Bearer | `https://ark.cn-beijing.volces.com/api/v3` | 同左（默认存储） | 补 |
| `doubao-intl`（BytePlus ModelArk） | 无（文档没写） | | `https://ark.ap-southeast.bytepluses.com/api/v3` | 同左 | 补（按火山方舟，待联调） |
| `ernie`（百度千帆） | `https://qianfan.baidubce.com/anthropic` | x-api-key | `https://qianfan.baidubce.com/v2` | 无 | 不补：文档没写 |
| `hunyuan-cn`（腾讯 TokenHub） | `https://tokenhub.tencentmaas.com` | x-api-key | `https://tokenhub.tencentmaas.com/v1` | 同左 | 补（文档要求） |
| `hunyuan-intl`（TokenHub 新加坡） | `https://tokenhub-intl.tencentcloudmaas.com` | Bearer | `https://tokenhub-intl.tencentcloudmaas.com/v1` | 同左 | 补 |
| `stepfun`（阶跃星辰） | `https://api.stepfun.com` | Bearer | `https://api.stepfun.com/v1` | 无 | 每个分片都带累计值，不用补 |

**Codex 只会 Responses 协议**。能直接用的：DeepSeek、百炼、智谱、Kimi、MiniMax、OpenAI、xAI、火山方舟、BytePlus、腾讯 TokenHub。Anthropic、Gemini、Mistral、千帆、阶跃没有 Responses，要等网关做协议转换（第 10 节）。国内前五家的 Responses 都是无状态的（不支持 `previous_response_id`、`store`）；OpenAI 有状态；火山方舟默认开启存储，要无状态得显式传 `store: false`。Codex 用自定义供应商时每次都发完整上下文，不依赖服务端存储。

**订阅类 key 和套餐地址不收**。编程套餐、订阅套餐的额度按各家条款只能在官方支持的编程工具里用，平台替用户中转属于违规：

- 按前缀拒绝的 key：百炼编程套餐 `sk-sp-`、MiniMax 订阅 `sk-cp-`、腾讯 Token Plan `sk-tp-`（条款写明“严禁 API 调用”）、Claude 订阅（Free、Pro、Max）的 OAuth 令牌 `sk-ant-oat…` / `sk-ant-ort…`（Anthropic 条款不允许第三方平台收集、保存或居间 Claude 账号凭证）。
- 自定义端点填了套餐专用地址就拒绝（每家的 `plan_only_bases`，`proto::vendors::plan_only_base` 逐家查；去掉首尾空白、转小写后等于它或接着是 `/`；只防误填，不是安全边界）：火山方舟 `/api/coding`、`/api/plan`，BytePlus `/api/coding`，千帆 `/v2/coding`、`/anthropic/coding`，腾讯 `api.lkeap.cloud.tencent.com/plan`、`tokenhub-intl…/plan`，阶跃 `/step_plan`，智谱 `/api/coding`。
- 没法按前缀分辨的：智谱编程套餐的 key 和按量付费共用 Anthropic 地址；火山方舟套餐用专属 key（前缀没公开）；阶跃 Step Plan 和按量付费是同一把 key、按地址计费。预置地址都是按量付费地址，界面上提示用户只填按量付费 key。千帆的套餐 key 调普通接口会被千帆自己拒绝（401）。

**会影响 agent 的差异**（详见表里每家的 `notes`）：

- DeepSeek 的 Chat Completions 默认开思考，带工具的请求必须回传之前每轮的 `reasoning_content`，否则 400。Pi、OpenClaw、Hermes 走 Chat Completions 时可能踩到，建议 DeepSeek 配 Anthropic 协议。DeepSeek 的 Anthropic 接口还会把不认识的模型名静默换成 `deepseek-flash`，别名配错了不会报错。
- MiniMax 的 Anthropic 流里 `message_start` 的用量不可信，以 `message_delta` 为准（网关按后到的覆盖，结果正确；只有中途断开的记录会偏）。MiniMax-M3 不设思考参数时，三种协议的默认行为不同。
- Kimi 按“输入 + max_completion_tokens”预占 TPM，同一账号下所有 key 共用额度；低等级账号跑 kimi-k3 容易 429。
- 智谱流式中途失败不返回错误码，只在最后一个分片的 `finish_reason` 里体现（如 `sensitive`、`network_error`）。
- 百炼的 key 可能被用户设了来源 IP 和模型白名单，网关的出口 IP 不在白名单里会被拒。
- Claude Opus 5.5 不能关思考、强制工具调用会报错、思考块绑定模型和会话：同一会话中途换上游模型会出错，降级链换到别的模型时要注意（第 10 节）。Anthropic 的 OpenAI 兼容层不返回思考内容、不支持提示缓存，官方说明不适合生产，Chat 类 agent 用 Claude 时效果打折扣。
- Gemini 已弃用的模型 id 会被静默转到新模型；思考签名要原样回传（网关透传不改请求体，不受影响）。
- xAI、阶跃的 Chat Completions 流式每个分片都带累计用量，网关取最后一个，不能累加。
- 腾讯原混元 API（`api.hunyuan.cloud.tencent.com`）已于 2026-09-30 停服，混元统一走 TokenHub。TokenHub 也托管其他厂商的模型；Anthropic 接口的缓存用量字段不完整，部分模型开思考时 `temperature` 必须为 1。
- 阶跃的 Anthropic 接口文档只列了部分请求字段（没有 `thinking`、`metadata`，思考强度用 `output_config.effort`），Claude agent 发的其他字段怎么处理要联调确认。
- 千帆发过“Anthropic API 返回参数 input_tokens 含义更新”的公告，计量要按新含义核对。

**待联调**（文档没写清，需要真实 key 验证）：DeepSeek、智谱的 Anthropic 接口是否也认 Bearer；百炼共享域名下的 `/compatible-mode/v1/responses`；智谱 Chat Completions 收到 `stream_options` 是忽略还是报错；DeepSeek、智谱 Anthropic 流里用量的位置；MiniMax Responses 流式事件和用量的位置；Mistral、千帆流式用量在哪个分片（现在都不补 `include_usage`，取不到就按估算记账）；BytePlus 是否支持 `include_usage`、有没有 Anthropic 兼容接口；腾讯 TokenHub 的 Responses 路径（按 OpenAI 兼容前缀推断）和新加坡站的 Anthropic 地址（按国内站推断）；xAI 是否还有 Anthropic 兼容接口（官方文档已不提）；千帆文心、BytePlus 豆包的模型 id（预置里留空，用户按控制台填）；阶跃国际站。

**依据**（9.12 部分，均为官方文档）：platform.claude.com/docs（models、api/overview、cli-sdks-libraries/libraries/openai-sdk）、code.claude.com/docs/en/legal-and-compliance；developers.openai.com/api/docs/models；ai.google.dev/gemini-api/docs/openai、/models；docs.x.ai/overview、/developers/model-capabilities/text/streaming；docs.mistral.ai/api、/models；ark.volcengine.com/region:cn-beijing/docs/82379/2160841、docs.volcengine.com/docs/ark/chat-api、/responses-api-migration；docs.byteplus.com/en/docs/ModelArk/model-list、/api/docs/ModelArk/2288685；cloud.baidu.com/doc/qianfan-docs/s/6mh3e6gjp、/doc/qianfan/s/imlg0beiu；cloud.tencent.com/announce/detail/2287、/document/product/1823/135874、/document/product/1823/130060、intl.cloud.tencent.com/zh/document/product/1300/80695；platform.stepfun.com/docs/zh/api-reference/chat/messages-create、/chat-completion-create、/step-plan/overview；docs.z.ai/devpack/tool/others。条款和模型变化很快，上线前复核。

## 12. 安全审查（2026-10-14）

对密钥库、沙箱令牌和网关做了一轮对抗式审查（按攻击面分四路找问题，每条再由另一个审查者尝试证伪，最后由完整性审查补漏）。确认的问题都已修复，并各有测试；把每个修复故意改回去，测试都会失败。

| 严重度 | 问题 | 修复 |
|---|---|---|
| 高 | 顶层重复键检查是平方复杂度，一个请求能把网关工作线程卡住很久 | 用哈希集合检查，顶层键最多 256 个 |
| 高 | agent 在厂商回响应头之前断开，这次调用不留记录、不记账 | 计量对象在请求发出前创建，被丢弃时也记一条 `client_closed` 并按估算记账 |
| 中 | `stream`、`stream_options` 先整个解析成 `Value` 再检查类型，内存放大约 16 倍 | 只按长度和字面值检查 |
| 中 | 没有入站超时，慢速连接能耗尽内存和文件描述符 | 自己接受连接：请求头 30 秒、请求体 60 秒，总连接数和每地址连接数上限 |
| 中 | 2xx 响应不带用量就记 0；Responses 后台模式能故意触发 | 取不到用量按保守估算记账；拒绝 `background: true` |
| 中 | 重复键只按字面比较，Go 写的中转服务按不区分大小写读出别的 `model`、`stream` | 不区分大小写比较；网关关心的键必须是标准写法 |
| 中 | 厂商的 SSE 事件和响应体整个解析成 `Value`（内存放大），超过 8 MiB 后整条流放弃取用量 | 只取用量相关字段；超大事件单独跳过，后面照常计量 |
| 低 | 错误体先截断再抹 key，截断处可能留下半截 key；短 key 不抹 | 多读 key 长度个字节再抹，去掉结尾残留的半截；任何长度的 key 都抹 |
| 低 | 解开的 DEK 在缓存过期后仍留在内存里（只在同一用户再来时才清），哈希表搬动时留下副本，AES 密钥调度不清零 | 每次取 DEK 时清掉所有过期条目；DEK 放堆上只搬指针；打开 aes-gcm 的 `zeroize`；`forget_user` 供注销时通知网关 |
| 低 | SSRF 拦截的报错能用来探测内网域名是否存在 | 只返回“不允许”，原因写日志 |

审查没采纳的三条（两路审查报了同一个竞态）：DEK 缓存与销毁之间的竞态（网关进程不执行销毁，攻击者够不着）；配出口代理时 DNS 重绑定只能靠代理拦截（已在第 8 节写明，属于部署要求）。


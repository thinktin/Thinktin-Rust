# 密码保险箱（WBS 9.11、11.6）

> 待决问题 9 的方案：对话、提示词不整体加密，账号密码单独进保险箱。agent 和模型都看不到明文，
> agent 只知道名字，用的时候由沙箱里的助手按名字注入命令。

## 1. 用户怎么用

- **自己存**：App 的保险箱页面新建条目，填名字（`github` 这样的引用名）、用途、账号、密码，可以限定哪些实例能用（默认全部）。
- **agent 来要**：agent 调 `vault_request`，App 收到推送和一张表单卡片（事件 `vault.requested`），用户填好提交（或拒绝）。
  填好的值只进保险箱；发起请求的那次运行已经结束时，平台在实例上接着跑一轮，告诉 agent 可以用了。
- **对话框里发密码**（11.6）：客户端发送前找出像密码、key 的内容（只在本地判断），提示不在对话里发明文，
  一键存进保险箱，消息里换成引用 `[vault:名字]` 再发。客户端没拦下来、直接发出去的，服务端建运行时把保险箱里
  已有的值换成引用再存库（agent 和模型都只看到引用）。

## 2. 存储和接口

| 接口 | 说明 |
|---|---|
| `GET /v1/vault` | 条目列表：名字、用途、有没有账号、能用它的实例、最近使用时间。**没有密码，也没有账号** |
| `POST /v1/vault` | 新建 `{name, purpose, username, password, instance_ids}`；同名 409，每人最多 200 条 |
| `GET /v1/vault/{id}` | 详情，多一个 `username`（解密后返回）。**密码永远不返回** |
| `PATCH /v1/vault/{id}` | 改用途、账号、密码、实例；只改其中一项时另一项保留 |
| `DELETE /v1/vault/{id}` | 删除 |
| `GET /v1/vault/requests[?all=true]` | agent 的填写请求，默认只要还在等的；过期（7 天）的读出来是 `expired` |
| `POST /v1/vault/requests/{id}/fulfill` | `{username, password, purpose?}`：存进保险箱（同名条目已有就更新它，并允许发起请求的实例使用） |
| `POST /v1/vault/requests/{id}/decline` | 拒绝 |

- 账号和密码一起用用户自己的 DEK 加密（AES-256-GCM），附加认证数据是单独的域 `thinktin/vault/v1/` 加用户 id 和条目 id：
  密文挪到别的用户、别的条目解不开，和模型 key、产出物的密文也不能互换（`keyvault::KeyVault::seal_vault`）。
- 名字：小写字母或数字开头，只含小写字母、数字、`_`、`-`，最长 64 个字符（不能有 `.`，引用字段时写 `github.username`）。
- 密码至少 4 个字符：再短就没法可靠地从对话和日志里抹掉。
- 表有 RLS；增删改记审计（只有名字，没有值）；注销账号时删除（DEK 销毁后密文本来也解不开）。

## 3. agent 怎么用

平台工具（MCP 服务器 `thinktin`，授权范围里要有）：

- `vault_list`：列出这个实例能用的条目（名字、用途、有没有账号）和还在等的请求，附用法说明。
- `vault_request {name, purpose, fields}`：请用户填。已经有能用的同名条目就直接返回 `available`；
  一次运行最多请求 5 次；同名的请求还在等就复用，不重复推送。

沙箱里的助手 `thinktin-vault`（agent-shim 启动时放进 agent 的 PATH）：

```sh
thinktin-vault exec --env GH_TOKEN=github -- gh repo list           # 环境变量
thinktin-vault exec --stdin db -- psql -U app -W                     # 标准输入
thinktin-vault exec -- curl -u '{{mail.username}}:{{mail.password}}' https://mail.example.com   # 参数里的占位符
```

引用写 `名字`（密码）或 `名字.username`、`名字.password`。助手连 shim 的工具桥 socket 要值，shim 发
`vault_reveal` 事件给平台，执行器核对后回 `vault_values` 指令（值只经 shim 的 stdin 交给助手，调试输出不显示）：

1. 这一轮的授权里有保险箱工具（`vault_list`），否则拒绝；
2. 条目存在、允许这个实例使用；
3. 解密，记审计 `vault.use`（运行、条目名）、运行日志 `vault.used`（只有名字），更新最近使用时间；
4. 解开的密码加进这次运行的抹值列表。

## 4. 抹值

模型永远看不到明文，日志里也没有：

- **运行日志**：执行器在运行开始时解开用户全部条目的密码，写运行日志（事件、工具输出）、运行摘要、审批的标题和工具调用之前抹掉，
  换成 `[vault:名字]`。agent 把值打印出来、写进文件再读出来，都一样会被抹掉。
- **模型网关**：转发前把用户保险箱里的值从请求里抹掉，模型看到的是 `[vault:名字]`。请求体逐个 JSON 字符串（包括键）
  解码后比较，不管 agent 的 SDK 怎么转义（Python 的 `\u00e9`、Go 的 `\u003c`）都认得出来，改过的字符串按标准写法编码回去，
  其余字节原样转发（`body::JsonObject::scrub`）。解开的值按用户缓存 5 秒；读不到保险箱（数据库出错）就不转发，返回 502。
- 每个值连同它的百分号编码（网址、表单里）和 JSON 转义形式一起找；重叠时取靠前、较长的。账号不算秘密，不抹。
  `keyvault::Scrubber`。

## 5. 已知限制和待办

- **出口代理注入**：能放进请求头的凭证（比如 API 的 `Authorization`）由出口代理按名字注入、沙箱里根本不出现明文，等出口代理（2.7）。
- **外发**：沙箱里的进程拿到了值，就可能把它发到网上（比如被网页里的提示词诱导）。抹值只管日志和模型；外发靠出网白名单（2.7）
  和条目的实例限制兜着。高危条目以后可以加“每次使用都要我批准”。
- 抹值按原文和两种编码找，base64 之类的其他编码（比如 HTTP Basic 认证头）认不出来。
- agent 把值写进平台工具的参数（比如计划目标、产出物内容），这些地方没有抹。
- 输入拦截是启发式的：没有标签的短密码、普通单词样的密码认不出来；用户坚持发送就照发，服务端只能换掉保险箱里已有的值。

## 7. 对话里的密码拦截（11.6）

App 发送消息前调 `detect_secrets(text)`（client-core，本地识别，不联网）。有命中就拦下，提示“对话里不收明文密码”，
弹表单：密码栏预填命中的值、名字预填建议名（重名用 `unique_vault_name` 换一个），用户确认后
`save_secret_from_message(message, value, item)` 存进保险箱，返回换成 `[vault:名字]` 的消息放回输入框。
`send_message(instance, text, allow_secrets)` 自己也检查一遍，有命中返回 `ContainsSecrets`；用户坚持要发（比如测试账号）时带 `allow_secrets`。

识别宁可漏不乱拦，只认：

| 类别 | 例子 | 建议名 |
|---|---|---|
| `private_key` | `-----BEGIN ... PRIVATE KEY-----` 块 | 多行，存不进保险箱（`storable = false`），只提示别发 |
| `api_key` | `sk-ant-`、`sk-proj-`、`ghp_`、`github_pat_`、`glpat-`、`xoxb-`、`AIza`、`AKIA`、`LTAI`、`hf_`、`sk-`（兜底）…… | 厂商名，比如 `anthropic`、`github`；`service` 字段给 App 判断要不要提示“添加为模型 key” |
| `token` | JWT（`eyJ...`，三段） | `token` |
| `url_password` | `postgres://app:密码@db.internal/prod` | `db_password` |
| `labeled` | `密码是 Abc123`、`密码：…`、`password: "a b c"`、`DB_PASSWORD=…`、`api key …`、`token …` | 标识符（`db_password`）或前一个词（`github 密码` → `github`） |
| `high_entropy` | 32 位以上、大小写字母和数字都不少、不是十六进制、不带 `.` `/` | `secret` |

不算：`[vault:名字]`、`${VAR}`、`{{...}}`、`<password>`、`****`、`your_...`、`password is required`、`password manager`、
提交号、UUID、路径、驼峰命名。位置给原生端的是 UTF-16 下标。

client-core 还有保险箱条目（`vault_items`、`vault_item`、`create_vault_item`、`update_vault_item`、`delete_vault_item`）
和 agent 填写请求（`vault_requests`、`fulfill_vault_request`、`decline_vault_request`）的接口，界面并入 12.4 / 13.4。

服务端兜底：用户坚持发送、或者旧版客户端没拦，建运行时把用户保险箱里已有的值换成引用再存库
（`gateway` 的 `runs::create`，和执行器共用 `orchestrator::vault::user_scrubber`），agent 和模型都只看到引用。
读不到保险箱时照常建运行，模型网关转发前还会再抹一遍（读不到就不转发）。

## 6. 测试

- `keyvault`：密文的域隔离、编码、抹值（原文、百分号编码、JSON 转义、重叠）。
- `store`：同名冲突、实例限制、按实例取密文、请求复用和处理、互相看不到、注销删除。
- `gateway`：响应里没有密码、库里只有密文、只改密码时账号保留、别人看不到改不了、填写请求和接着跑一轮。
- `orchestrator`：工具只列名字、请求推送和上限；助手拿到值、运行日志和摘要里看不到值、没有授权拿不到。
- `agent-shim`：工具桥的 `reveal`、助手的参数解析和占位符、环境变量 / 标准输入注入和退出码、启动脚本的路径转义。
- `llm-gw`：各种转义写法的抹值、没有要抹的请求一个字节都不改；接库时用网关角色读得到密文、解得开。
- `client-core`：识别的各类命中和不该命中的（`secrets.rs`）；对着真实接入网关拦下发送、存进保险箱后换成引用再发、重名、条目和填写请求的接口、FFI 的 UTF-16 下标（`tests/client.rs`）；C ABI 冒烟（`tools/client-core/ffi_smoke.py`）。
- `gateway`（11.6）：建运行时消息里的保险箱值换成引用、库里存的是引用，别人发同样的文字不受影响。

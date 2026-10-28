# ACS 智能体沙箱后端

> 更新日期：2026-10-28　｜　状态：按 OpenKruise Agents（release-v0.6，`openkruise/agents`）的 E2B 兼容私有协议实现，模拟服务测试通过；工作区归档到 OSS（第 6 节）和东京的部署配置（`deploy/k8s/overlays/tokyo`）写好了。ACS 东京集群上的实测见第 8 节，还没做。

10 个用户的测试上线用阿里云容器计算服务 ACS 的智能体沙箱（[阿里云部署计划](deploy-aliyun-sg.md) 第 8 节）：集群里装 `ack-sandbox-manager`（OpenKruise Agents 的 sandbox-manager），每个沙箱是一个 Pod。`crates/sandbox/src/acs.rs` 的 `AcsProvider` 按它的私有协议实现 `SandboxProvider`；进程和文件走沙箱里的 envd，客户端和 Cube 后端共用（`crates/sandbox/src/envd.rs`）。

## 1. 接口对应

控制面都在 `<api_url>` 下（一般是 `http://<域名>/kruise/api`），请求带 `X-API-KEY`（sandbox-manager 的 `adminApiKey`）。

| `SandboxProvider` | sandbox-manager | 说明 |
|---|---|---|
| `create` | `POST /sandboxes` | `templateID` 是 SandboxSet 的名字（见第 2 节）；`timeout: 300`（它只收 30 秒到 30 天）+ 扩展 `e2b.agents.kruise.io/never-timeout: "true"`（不按空闲回收，暂停、归档由控制服务巡检决定）；`allow_internet_access: false` + `network.allowOut`（只放行白名单：IP、CIDR 或域名，不分端口、不能用通配符）；扩展 `return-sandbox-ip: "true"` 要 Pod IP；原始模板和工作区记在元数据里。没有卷、`secure`、`allowPublicTraffic` |
| `get` | `GET /sandboxes/{id}` | `running`、`paused` 照报；`dead`（到了关机时间之类）先 `DELETE` 再报不存在，免得控制服务重建后留下一个；别的状态报错，不当成暂停 |
| `exec` | envd `process.Process/Start`（Connect 流） | 同 Cube；这个版本的 envd 没有 `CloseStdin`，标准输入关掉后只是不再转发 |
| `pause` | `POST /sandboxes/{id}/pause` | 204 成功；409 时查一下，确实暂停了就算成功。不设暂停后的保留时长：never-timeout 的沙箱 sandbox-manager 不按它删（没有关机时间），删不删全由我们的巡检决定 |
| `resume` | `POST /sandboxes/{id}/connect`（`timeout: 300`） | `timeout` 必须大于 0，never-timeout 的沙箱不会据此改超时；正在暂停时（409、503，或恢复撞上冲突的 400）隔 2 秒重试 5 次；之后再 `GET` 一次，以那时的 Pod IP 为准 |
| `snapshot`、`restore` | 不支持 | 报错 |
| `destroy` | `DELETE /sandboxes/{id}` | 不存在也报 204；409、503 重试 |
| `delete_workspace` | 无 | 没有卷，工作区随沙箱删掉 |
| `write_file` | envd `MakeDir` + `POST /files` | 只发 multipart（这个版本的 envd 收到别的格式报 500，没法据此回退） |
| `read_file` | envd `GET /files` | 同 Cube |

数据面发到 `<data_url>/kruise/<沙箱 id>/49983/<路径>`，sandbox-manager 把路径改写成 `/<路径>` 转给 Pod 里的 envd。`data_url` 不配就是 `api_url` 去掉 `/kruise/api`。每个请求带 envd 的 `X-Access-Token` 和 `Authorization: Basic <用户>:`，不带 API Key。令牌只在内存里；控制服务重启后 `GET` 一次，运行中的沙箱响应里就有令牌，不用 `connect`。

## 2. 模板

SandboxSet 的名字必须是 Kubernetes 的名字，清单里的模板 id（如 `agents/claude:0.90.0`）不是。`[sandbox.acs.templates]` 按模板 id 映射；没列的按规则规整：小写，别的字符换成 `-`，合并、去掉首尾的 `-`，最多 63 个字符（`agents/claude:0.90.0` → `agents-claude-0-90-0`）。每个模板一个 SandboxSet，CPU、内存按清单的 `[runtime]` 配（Claude 是 1 核 2 GiB）。

目录约定同 Cube（[CubeSandbox 后端](sandbox-cube.md) 第 2 节）：`/sandbox/home` 是 HOME，`/sandbox/workspace` 是工作区（这里在沙箱自己的磁盘上），进程以 `user` 运行。镜像里要有 envd（端口 49983）和 agent-shim。

## 3. 配置

```toml
[sandbox]
provider = "acs"
network_allow = ["10.0.0.20"]               # 沙箱只能连模型网关：只写地址（allowOut 不分端口，带端口会报错），端口靠安全组
gateway_url = "http://10.0.0.20:8790"

[sandbox.acs]
api_url = "http://<sandbox-manager 域名>/kruise/api"
# data_url = "http://<域名>"                 # 不配就是 api_url 去掉 /kruise/api
# root = "/sandbox"、user = "user"、ip_wait_secs = 15、request_timeout_secs = 120

[sandbox.acs.templates]
"agents/claude:0.90.0" = "agents-claude-0-90-0"

[sandbox.workspace]
mode = "object"                             # 必须：ACS 没有卷，工作区归档到 [storage]（第 6 节）
# max_bytes = 4294967296、archive_timeout_secs = 1800、temp_dir = "/tmp"

[sandbox.lifecycle]                         # 计时，不配用默认值（空闲 10 分钟暂停、暂停 7 天归档）
idle_pause_secs = 600
archive_after_secs = 3600                   # 东京测试环境：暂停 1 小时就删沙箱
keep_if_trigger_within_secs = 0             # 有计划的也归档……
prewarm_lead_secs = 300                     # ……到点前 5 分钟建好、放回工作区
pause_waiting_approval = false              # 等审批时不暂停（暂停后 agent 进程能不能接上没实测）
```

API Key 放环境变量 `THINKTIN_ACS_API_KEY`（sandbox-manager 的 `adminApiKey`，`deploy/aliyun/acs.py` 生成，只存在 `target/` 下）。后台副本开着时不配 Key 起不来；`mode = "volume"` 也起不来。

东京测试环境的完整配置在 `deploy/k8s/overlays/tokyo/server.toml`。还没定的一处：服务机（集群外、同一个 VPC）怎么访问 sandbox-manager——ACS 没有节点，服务要用内网负载均衡暴露出来（收费，下单前查价），或者后台副本挪进集群。

## 4. 沙箱令牌绑定 Pod IP

每个 ACS 沙箱是一个 Pod，出网不经 SNAT，模型网关看到的来源地址就是 Pod IP。所以：

- 创建时要 sandbox-manager 返回 Pod IP（`return-sandbox-ip`），响应元数据里的 `e2b.agents.kruise.io/sandbox-ip` 就是 `SandboxInfo::address`。sandbox-manager 把它写在存储的元数据之后，沙箱里的程序改不了。
- 创建响应里还没有 IP 时（Pod 刚就绪），每 0.5 秒查一次，最多 `ip_wait_secs`。还拿不到就删掉沙箱、创建失败——不退回到不绑定的令牌。
- 恢复后 IP 可能变：以恢复后 `GET` 到的为准，拿不到就报错（沙箱保留）。控制服务发现运行中的沙箱换了地址也会记下新的，下一个沙箱令牌绑新地址。
- 从不从沙箱里面问 IP（答案可能被 agent 改）。

模型网关要直接看到 Pod IP：中间不能有 NAT、负载均衡或反向代理（会把来源换掉，所有请求都会被拒）。

## 5. 和 Cube 后端不一样的地方、已知限制

| 问题 | 影响 | 处理 |
|---|---|---|
| 没有卷 | 销毁沙箱工作区就没了 | `[sandbox.workspace] mode = "object"`：归档前把工作区加密打包存到 OSS，重建时放回（第 6 节）。没配时控制服务不归档、不重建，暂停的沙箱一直留着 |
| 暂停的沙箱也收费 | 每个暂停的沙箱按 30 GiB 临时存储计费（约 ¥36/月） | 暂停 `archive_after_secs` 后归档（东京测试环境 1 小时） |
| 没有快照 | 换机恢复（7.12）用不了 | 不需要：沙箱丢了就从模板重建（接上对象存储后从归档放回） |
| envd 没有 `CloseStdin` | 关标准输入不会让进程读到 EOF | agent-shim 靠命令或被结束退出 |
| `allowOut` 不收通配符、不分端口 | 白名单只能写 IP、CIDR 或具体域名；放行一个地址就是放行它的所有端口 | 模型网关用 IP；`network_allow` 带端口启动时就报错。服务机的安全组只许沙箱的网段连 8790（数据库、k3s 的 6443、kubelet 都在服务机上），ACS 的 Pod 不要和服务机用同一个安全组（同组默认互通） |
| 集群内是明文 HTTP | sandbox-manager、envd、模型网关之间的令牌在 VPC 里明文传 | 10 个用户的测试先接受；安全组只放行需要的端口 |

## 6. 工作区归档（`mode = "object"`）

没有卷的后端（`SandboxProvider::workspace_persists()` 是 false）上，控制服务（`crates/control`）在销毁沙箱前把工作区存进对象存储，从模板重建沙箱时放回：

- **存**（巡检归档、手动归档、换版本重建）：沙箱暂停着就先恢复，在沙箱里跑 `tar --create --gzip --file=- .`（工作目录是工作区；agent 的会话状态在 `workspace/.thinktin/` 下，一起存），标准输出经 `ObjectWorkspaceStore`（`crates/orchestrator/src/workspaces.rs`）按用户 DEK 分块加密（每块 1 MiB，AES-256-GCM，AAD 里有用户、归档 id、块序号、是不是最后一块），密文写进临时文件，再整个上传到 `workspaces/<用户>/<工作区>/<归档 id>`。GNU tar 退出码 1（有文件在打包时变了）也算成功。
- **三步各自提交**：先在实例上记下要上传的对象（`workspace_archive_pending`），上传完记下归档（键、id、大小、明文的 SHA-256），最后销毁沙箱、记为已归档。中途出错：没记成的上传排进清理队列，为打包恢复过的沙箱再暂停回去，实例保持暂停；进程被杀：下次归档换掉待定的对象、排进清理队列。工作区不会丢。
- **放**：建好新沙箱后，下载到临时文件，逐块解密，经 envd 一个 multipart 上传传到沙箱的 `workspace/.thinktin/restore.tgz`，在沙箱里 `tar --extract --gzip --no-same-owner`，再删掉临时文件。大小或摘要对不上、解不开、解包失败：唤醒失败，新沙箱删掉，实例还是已归档、归档还在。打包、解包都在沙箱里做，服务端不解析用户的文件，只有密文落盘。
- **什么时候存**：巡检（暂停超过 `archive_after_secs`，没有在跑、等审批的运行，`keep_if_trigger_within_secs` 内没有计划要触发）；手动归档；换版本、重建。每个实例单独一个事务，存的时候一直锁着这个实例（期间要唤醒它的等存完），不挡别的实例。
- **预热**：计划快到点（`prewarm_lead_secs`）时，归档了的实例也提前重建、放回工作区。
- **沙箱自己没了**（不是归档掉的）：从模板重建，放回最后一份归档，日志 `restored a stale workspace archive`（最近的改动没存下来）。
- **清理**：每个实例只留最新的一份。换掉的、没用上的、回收或删除实例时的对象，由数据库触发器排进 `blob_purge`，和产出物一起由后台删掉（迁移 0023）。注销账号时用户 DEK 先删，归档立即解不开（加密销毁）。
- **上限**：`max_bytes`（默认 4 GiB）超了不归档、沙箱暂停着留下；`archive_timeout_secs`（默认 30 分钟）管上传、下载各一次；临时文件在 `temp_dir`（后台副本的 `/tmp`，东京配置给了 10 GiB）。
- **模板镜像要有 GNU tar 和 gzip**（Debian 基础镜像自带）。

本地开发也能走一遍：`provider = "local"` 加 `mode = "object"`，本地后端不用卷（`LocalProvider::without_volumes`），归档放 `[storage]` 的本地目录。

## 7. 和卷相比要知道的

| 问题 | 影响 |
|---|---|
| 存、放要时间 | 和工作区大小成正比（打包、加密、经 VPC 传 OSS）；唤醒已归档的实例比恢复暂停的慢，见第 8 节的实测 |
| 存的时候锁着实例 | 正好在归档时来消息，要等存完、再重建放回 |
| 只存工作区 | `/sandbox/home`（HOME）和工作区外的东西不存：agent 的状态要放在工作区里（我们的 agent-shim 放在 `workspace/.thinktin/home`） |
| 套接字、正在写的文件 | tar 跳过套接字；打包时还在变的文件可能是半截的（归档只在没有运行时做） |

## 8. 待实测（东京集群上，要在集群 VPC 里跑，见 [交接文档](handoff.md)）

- v0.6.13 的创建、`GET`、`connect` 响应里有没有 `e2b.agents.kruise.io/sandbox-ip`；暂停、恢复后 IP 变不变。
- 模型网关拒绝日志里的 `peer` 是不是 Pod IP（中间有没有 SNAT）。
- `timeout: 300` + never-timeout 能不能建，`connect` 后还是不是 never-timeout。
- `Start` 的 `stdin` 字段、`SendInput`、`CloseStdin` 的 404；长时间没输出时流会不会断（`Keepalive-Ping-Interval: 30`）；暂停时开着的流恢复后还在不在。
- `/files` 上传、下载的大小上限和速度。
- 出网：只能连模型网关，连不上 `100.100.100.200` 和别的沙箱。
- admin Key 能不能找到 `default` 命名空间里的 SandboxSet。
- 暂停期间的计费和保留时长。
- 工作区归档：模板镜像里有没有 GNU tar；500 MB 的工作区存、放各要多久；OSS 的 S3 兼容接口签名区域写 `oss-ap-northeast-1` 还是 `ap-northeast-1`。
- 服务机怎么访问 sandbox-manager（第 3 节）。

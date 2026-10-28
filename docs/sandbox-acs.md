# ACS 智能体沙箱后端

> 更新日期：2026-10-28　｜　状态：按 OpenKruise Agents（release-v0.6，`openkruise/agents`）的 E2B 兼容私有协议实现，模拟服务测试通过；ACS 东京集群上的实测见第 6 节，还没做。

10 个用户的测试上线用阿里云容器计算服务 ACS 的智能体沙箱（[阿里云部署计划](deploy-aliyun-sg.md) 第 8 节）：集群里装 `ack-sandbox-manager`（OpenKruise Agents 的 sandbox-manager），每个沙箱是一个 Pod。`crates/sandbox/src/acs.rs` 的 `AcsProvider` 按它的私有协议实现 `SandboxProvider`；进程和文件走沙箱里的 envd，客户端和 Cube 后端共用（`crates/sandbox/src/envd.rs`）。

## 1. 接口对应

控制面都在 `<api_url>` 下（一般是 `http://<域名>/kruise/api`），请求带 `X-API-KEY`（sandbox-manager 的 `adminApiKey`）。

| `SandboxProvider` | sandbox-manager | 说明 |
|---|---|---|
| `create` | `POST /sandboxes` | `templateID` 是 SandboxSet 的名字（见第 2 节）；`timeout: 300`（它只收 30 秒到 30 天）+ 扩展 `e2b.agents.kruise.io/never-timeout: "true"`（不按空闲回收，暂停、归档由控制服务巡检决定）；`allow_internet_access: false` + `network.allowOut`（只放行白名单，不能用通配符）；扩展 `return-sandbox-ip: "true"` 要 Pod IP；配了 `paused_retention` 时加 `reserve-paused-sandbox-duration`；原始模板和工作区记在元数据里。没有卷、`secure`、`allowPublicTraffic` |
| `get` | `GET /sandboxes/{id}` | `running`、`paused` 照报；`dead`（到了关机时间之类）先 `DELETE` 再报不存在，免得控制服务重建后留下一个；别的状态报错，不当成暂停 |
| `exec` | envd `process.Process/Start`（Connect 流） | 同 Cube；这个版本的 envd 没有 `CloseStdin`，标准输入关掉后只是不再转发 |
| `pause` | `POST /sandboxes/{id}/pause` | 204 成功；配了 `paused_retention` 时带头 `x-e2b-kruise-reserve-paused-sandbox-duration`；409 时查一下，确实暂停了就算成功 |
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
network_allow = ["10.0.0.20:8790"]          # 沙箱只能连模型网关；allowOut 不收通配符，用 IP
gateway_url = "http://10.0.0.20:8790"

[sandbox.acs]
api_url = "http://<sandbox-manager 域名>/kruise/api"
# data_url = "http://<域名>"                 # 不配就是 api_url 去掉 /kruise/api
# paused_retention = "forever"              # 暂停后保留多久，不配用 sandbox-manager 的默认值
# root = "/sandbox"、user = "user"、ip_wait_secs = 15、request_timeout_secs = 120

[sandbox.acs.templates]
"agents/claude:0.90.0" = "agents-claude-0-90-0"
```

API Key 放环境变量 `THINKTIN_ACS_API_KEY`（sandbox-manager 的 `adminApiKey`，`deploy/aliyun/acs.py` 生成，只存在 `target/` 下）。后台副本开着时不配 Key 起不来。

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
| 没有卷 | 销毁沙箱工作区就没了 | `workspace_persists()` 报 false：控制服务不归档、不重建（版本升级会报错），暂停的沙箱一直留着。之后接上对象存储：归档前把工作区加密打包存到 OSS，重建时放回 |
| 暂停的沙箱也收费 | 每个暂停的沙箱按 30 GiB 临时存储计费（约 ¥36/月） | 同上，接上对象存储后空闲一小时内删掉 |
| 没有快照 | 换机恢复（7.12）用不了 | 不需要：沙箱丢了就从模板重建（接上对象存储后从归档放回） |
| envd 没有 `CloseStdin` | 关标准输入不会让进程读到 EOF | agent-shim 靠命令或被结束退出 |
| `allowOut` 不收通配符 | 白名单只能写 IP、CIDR 或具体域名 | 模型网关用 IP |
| 集群内是明文 HTTP | sandbox-manager、envd、模型网关之间的令牌在 VPC 里明文传 | 10 个用户的测试先接受；安全组只放行需要的端口 |

## 6. 待实测（东京集群上，要在集群 VPC 里跑，见 [交接文档](handoff.md)）

- v0.6.13 的创建、`GET`、`connect` 响应里有没有 `e2b.agents.kruise.io/sandbox-ip`；暂停、恢复后 IP 变不变。
- 模型网关拒绝日志里的 `peer` 是不是 Pod IP（中间有没有 SNAT）。
- `timeout: 300` + never-timeout 能不能建，`connect` 后还是不是 never-timeout。
- `Start` 的 `stdin` 字段、`SendInput`、`CloseStdin` 的 404；长时间没输出时流会不会断（`Keepalive-Ping-Interval: 30`）；暂停时开着的流恢复后还在不在。
- `/files` 上传、下载的大小上限和速度。
- 出网：只能连模型网关，连不上 `100.100.100.200` 和别的沙箱。
- admin Key 能不能找到 `default` 命名空间里的 SandboxSet。
- 暂停期间的计费和保留时长。

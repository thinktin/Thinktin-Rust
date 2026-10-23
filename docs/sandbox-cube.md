# CubeSandbox 后端（WBS 6.2）

> 更新日期：2026-10-16　｜　状态：按 CubeSandbox 的 `openapi.yml`（v0.7）和 envd 的 Connect 协议实现，模拟服务测试通过；真实集群联调待 2.3 部署。

生产环境的沙箱跑在腾讯开源的 [CubeSandbox](https://github.com/TencentCloud/CubeSandbox) 上（架构方案第 6 节、附录 A）。`crates/sandbox/src/cube.rs` 的 `CubeProvider` 按 Cube 的 E2B 兼容接口实现 `SandboxProvider`，控制服务、执行器不用改。

## 1. 接口对应

| `SandboxProvider` | Cube | 说明 |
|---|---|---|
| `create` | `POST /sandboxes` | `timeout: -1`（不按空闲回收，暂停、归档由控制服务巡检决定）；`secure: true`；`allow_internet_access: false` + `network.allowOut`（只放行白名单）；`network.allowPublicTraffic: false`（数据面要带流量令牌）；工作区卷挂到 `<root>/workspace`；原始模板和工作区记在元数据里 |
| `get` | `GET /sandboxes/{id}` | `running` 算运行中，`paused`、`pausing`、`unknown` 都按暂停处理（控制服务会去恢复，恢复是幂等的） |
| `exec` | envd `process.Process/Start`（Connect 流） | 输出流里的 `start`、`data`、`end` 事件转成管道；标准输入经 `SendInput` 转发，写的一方关掉后调 `CloseStdin`；`kill` 发 `SendSignal`（SIGKILL） |
| `pause` | `POST /sandboxes/{id}/pause` | 已暂停时 Cube 报 409，查一下状态，确实不在运行就算成功 |
| `resume` | `POST /sandboxes/{id}/connect`（`timeout: -1`） | `resume` 接口 Cube 已标为过时；`connect` 恢复暂停的沙箱并返回数据面令牌 |
| `snapshot` | `POST /sandboxes/{id}/snapshots` | 内存 + 磁盘 |
| `restore` | `POST /sandboxes`，`templateID` 填快照 id | Cube 的快照可以直接当模板建沙箱 |
| `destroy` | `DELETE /sandboxes/{id}` | 不存在算成功；503（正在暂停等）按 `Retry-After` 重试 |
| `delete_workspace` | `GET /volumes` 按名字找到卷，`DELETE /volumes/{id}` | |
| `write_file` | envd `filesystem.Filesystem/MakeDir` + `POST /files` | 先建上级目录；先发 `application/octet-stream`，老版本 envd 报 400、415 时改发 multipart |
| `read_file` | envd `GET /files` | 超过上限不读进内存（先看 `Content-Length`，再边读边数） |

数据面的请求发到 `49983-<沙箱 id>.<域名>`：配了 `proxy_url` 就直接连 CubeProxy、用 Host 头路由（不需要泛域名 DNS），否则按 `<data_scheme>://49983-<沙箱 id>.<域名>` 解析。每个请求带 envd 的 `X-Access-Token`、流量令牌（`e2b-traffic-access-token`、`cube-traffic-access-token`）和 `Authorization: Basic <用户>:`（进程以这个用户运行）。令牌只在内存里，不打日志；控制服务重启后，确认沙箱在运行，再调一次 `connect`（不改超时）取回令牌。

## 2. 模板约定（6.8 构建模板时照这个做）

模板的构建和冒烟见 [agent 的沙箱模板](templates.md)。

| 项 | 约定 |
|---|---|
| 根目录 | `/sandbox`（`[sandbox.cube] root` 可改）。trait 里的相对路径都相对它 |
| HOME | `/sandbox/home`，属于运行用户。exec 时设 `HOME`（和本地后端一致：agent 的状态在 HOME 下，不在工作区卷上） |
| 工作区 | `/sandbox/workspace`，Cube 卷挂在这里；默认工作目录 |
| 用户 | `user`（`[sandbox.cube] user` 可改），对 `/sandbox/home`、`/sandbox/workspace` 有写权限；不用 root |
| envd | 镜像里要有 envd，探活端口 49983（`cubemastercli tpl create-from-image --expose-port 49983 --probe 49983`） |
| agent-shim | 在 `PATH` 上（执行器按 `[sandbox] shim_path` 启动，默认 `agent-shim`） |
| 资源 | CPU、内存按模板分配，`CreateSpec::resources` 不起作用 |

## 3. 配置

```toml
[sandbox]
provider = "cube"
network_allow = ["llm-gw.internal:8790"]   # 沙箱只能连模型网关
gateway_url = "http://llm-gw.internal:8790"

[sandbox.cube]
api_url = "http://cube-api:3000"           # E2B_API_URL
proxy_url = "http://10.0.0.5"               # CubeProxy；不配就走泛域名 DNS
egress_address = "10.0.0.20"                # 模型网关看到的沙箱来源地址（必填）
volume_driver = "nfs"                       # 卷插件；不配用 CubeMaster 的默认插件
# root = "/sandbox"、user = "user"、data_scheme = "https"、use_volumes = true、request_timeout_secs = 120
```

CubeAPI 开了鉴权（`--auth-callback-url`）时，key 放环境变量 `THINKTIN_CUBE_API_KEY`。

## 4. 和本地后端不一样的地方、已知限制

| 问题 | 影响 | 处理 |
|---|---|---|
| 沙箱出网经 Cube 节点 SNAT | 模型网关看不到单个沙箱的地址，沙箱令牌的来源地址只能绑到节点出网地址（`egress_address`），同一出口下的沙箱之间拦不住被带走的令牌 | 令牌仍绑定实例、当前沙箱 id、运行授权，短期有效、唤醒即轮换。后续可以让 CubeEgress 在去模型网关的请求上注入沙箱身份头（Cube 的 L7 规则支持按目标注入请求头），网关核对它（待 2.7 出口策略一起做） |
| `allowOut` 只按地址或域名放行，不分端口 | 白名单里的 `host:port` 只取 host | 白名单本来就只有模型网关 |
| 卷插件 | 集群没配卷插件时建沙箱会失败 | `use_volumes = false` 可以先不用卷（工作区随暂停、快照保留，重建沙箱会丢） |
| 快照 | Cube 的快照和沙箱生命周期独立，这里没有删除快照的接口 | 换机恢复（7.12）做时补清理 |

## 5. 待联调（真实集群上确认）

- envd 的 `CloseStdin`：E2B 较新的 envd 才有，没有时标准输入只是不再转发，agent-shim 要靠命令或被结束退出。
- `POST /files` 收 `application/octet-stream` 还是只收 multipart；`MakeDir` 遇到已存在目录的返回。
- `Keepalive-Ping-Interval` 头是否生效（长时间没有输出时，CubeProxy 和中间网络会不会断开流）。
- `connect` 对运行中沙箱传空请求体时确实不改超时；`timeout: -1` 对暂停后恢复的沙箱生效。
- 从快照建沙箱时同名工作区卷能否再挂上；`metadata` 是否随快照保留。
- 进程被信号结束时 envd 报的 `exitCode`、`status`（现在按 Go 的 `signal: killed` 解析）。
- 经 `proxy_url` + Host 头访问时，CubeProxy 是否要求 TLS（现在按 http 直连内网）。

## 6. 测试

`crates/sandbox/tests/cube.rs` 起一个模拟服务（照 Cube 的 `openapi.yml` 和 envd 的 Connect 协议），走完创建、查询、执行（环境变量、工作目录、标准输入回显、标准错误、退出码、kill、找不到可执行文件）、文件（上级目录、上限、不存在、路径越界）、暂停后不能执行、重复暂停、恢复、快照恢复、销毁、删卷，以及控制服务重启后重新取令牌。

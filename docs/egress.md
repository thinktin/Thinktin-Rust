# 沙箱的受控出网通道（WBS 2.7）

本页是东京内测的实现方案。当前集群配置只允许沙箱访问模型网关，本文描述的代理、配额、审计与客户端开关均待实现。[东京配置](../deploy/k8s/overlays/tokyo/server.toml) · [现有实现和供应商调研](progress/drafts/egress-survey.md)

## 五种 agent 需要什么网络

五个模板已把模型地址指向 Thinktin 网关。基本对话、审批和恢复会话沿用这条专线。以下区分仓库对锁定版本已有的断网观测、工具的额外需求，以及仍需在容器验证的部分。[配置生成器](../crates/agent-shim/src/config.rs) · [既有网络审计](agent-integration.md) · [模板版本](../crates/catalog/manifests)

- **Claude Code** 的 ACP 与命令行模式都关闭自动更新和非必要联网。企业代理支持 HTTP(S) 代理环境变量。远程 MCP、工具调用的目标网站及厂商托管搜索涉及不同的连接；在模型网关明确支持对应工具之前，沙箱只提供本地预装工具和经批准的网页获取。[上游网络配置](https://code.claude.com/docs/en/network-config)
- **Codex** 使用自定义 Responses 提供方；插件、Apps、自动更新、分析和反馈均已关闭。无需给插件市场开 GitHub 或 ChatGPT 全站权限。提供方执行的搜索不会经过沙箱代理，需要在模型网关的工具策略另行限制。开发网站预设可参考上游分类，平台应维护自己的域名清单。[Codex 云环境清单](https://developers.openai.com/codex/cloud/internet-access/)
- **Pi** 使用镜像锁定的 CLI 与 ACP 适配器，设置离线、跳过版本检查和关闭遥测。基础工具可执行 shell；安装扩展会引入 npm 或 Git 下载，仅在构建时安装已审核扩展。扩展自己的 HTTP 客户端仍须逐个测代理。[Pi 源码和扩展](https://github.com/earendil-works/pi)
- **OpenClaw** 使用沙箱内的 gateway sidecar。模板已关闭模型目录刷新、自动更新和遥测。已有审计仍观察到 ClawHub 插件目录请求，应继续拒绝。网页获取连接目标站点，网页搜索还取决于所选搜索供应商；默认不提供服务密钥。新增已批准供应商时单列域名、费用和经手数据。[上游网页工具](https://docs.openclaw.ai/tools/web)
- **Hermes** 使用自定义模型端点，并跳过 Node 引导下载。基础运行的审计只看到探测本地模型网关。网页搜索与提取可以经独立服务，不能由模型网关可用推断这些服务可用。浏览器和所需程序预装，缺少可选服务时向调用者返回不可用。[上游网页搜索与提取](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-search/)

**运行时与镜像构建分开。** npm、PyPI 和系统包在受信的构建机下载。用户明确选择“开发网站”时，先按需求放行精确主机。npm 用 `registry.npmjs.org`；PyPI 用 `pypi.org`、`files.pythonhosted.org`；Cargo 用 `index.crates.io`、`static.crates.io`；Go 模块用 `proxy.golang.org`、`sum.golang.org`。GitHub Git HTTPS、源码包与 raw 文件分别用 `github.com`、`codeload.github.com`、`raw.githubusercontent.com`。发布附件如跳转到 CDN，按实际主机另行核准。Docker Hub、Hugging Face、apt 镜像或私有仓库按项目显式添加。共享托管域名能承载用户内容，允许连接该域名意味着能向其中的其他租户传输数据。

**代理适配。** shim 下发小写 `http_proxy`、`https_proxy` 和大写 `HTTPS_PROXY`；本机地址及模型网关精确加入 `no_proxy`。Node 模板以支持内置环境代理的具体版本启用 `NODE_USE_ENV_PROXY=1`。curl、Git HTTPS、Python urllib 和 Node fetch 可运行下方探针，成功意味着代理收到了 CONNECT。HTTPX 的 `trust_env=False`、应用自建 HTTP agent、原生二进制、扩展脚本需要另外验证。pip、uv、Cargo、Go、npm/pnpm、Yarn Berry 与 apt 分别在模板内安装一个锁定依赖，检查代理日志；忽略环境变量的工具只会得到网络失败。git+ssh、原始 TCP、QUIC/UDP 不进入这个通道。安全边界始终由网络层执行。[curl](https://everything.curl.dev/usingcurl/proxies/env.html) · [Node](https://nodejs.org/api/cli.html#--use-env-proxy) · [Git](https://git-scm.com/docs/git-config) · [HTTPX](https://www.python-httpx.org/environment_variables/)

```sh
python3 tools/smoke/egress-clients.py
```

## 东京内测的连接路径

1. 沙箱的默认路由继续禁止公网。ACS `allowOut` 仅填网关与代理的服务 IP，服务机安全组再放行各自的监听端口。拒绝直连公网 IP、任意 DNS/DoH 出口、UDP、IPv6 旁路和访问 VPC 的其他服务。代理地址以固定 IP 注入，域名在服务端解析。
2. 首版采用显式 HTTPS CONNECT 隧道。首选对 [Smokescreen](https://github.com/stripe/smokescreen) 做接入验证，利用其 CONNECT/DNS/ACL 能力；由受信控制面绑定实例身份、策略代数、活动租约与配额。匿名 Pod IP 不能单独作为凭证。连接同时核对短期代理凭证、Pod 源 IP 和实例代数；实例回收后旧令牌即失效。ACS 若保不住源 IP，必须先解决可靠身份绑定。
3. 客户端只使用 `CONNECT host:443`；HTTP 明文 80 留待有明确需求时单列支持，避免 CONNECT 任意端口。只允许规范化的 DNS 名称；拒绝用户信息、路径、控制字符、IP 字面量、非标准数字地址和有歧义的端口。精确域名匹配；若以后支持后缀，按 DNS 标签边界匹配。每个 CONNECT 重做授权。
4. 由可信解析器解析完整结果。任一 A/AAAA 属于非公网、元数据地址、VPC、服务机自身或部署禁段就整体拒绝；校验 IPv4 映射、NAT64 和特殊用途地址。直接连已校验的 socket 地址，重试也只用本次校验集合。[现有 SSRF 判定](../crates/llm-gw/src/ssrf.rs) · [IANA IPv4](https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml) · [IANA IPv6](https://www.iana.org/assignments/iana-ipv6-special-registry/iana-ipv6-special-registry.xhtml)
5. 普通 TLS 端到端透传。CONNECT 只能证明选定的目标主机和地址，无法保证同一 CDN 上加密流量的 Host、路径或租户。对有保密要求的项目使用只连模型档，或专用包镜像。保险箱按域注入凭据走独立的显式授权流程，域名、协议和目标校验单独验收；普通代理不安装通用解密 CA。[保险箱设计](vault.md)
6. 策略收紧、账号冻结、实例回收或撤销授权时，关闭现存隧道。按实例与用户分别计双向字节、并发和速率，预留配额后才转发；跨副本共享计数，控制面不可用时拒绝新隧道。隧道有空闲和总时限。日志记录实例、规则/版本、目标主机和端口、批准或拒绝原因、字节数与时间，不记录路径、令牌、正文或 TLS 内容。

## 开关与验收

**用户 2026-11-04 拍板：**

1. 所有实例（新建的也一样）默认“只连模型”，用户在实例设置里自己选“开发网站”或“自定义网站”。
2. 内测**提供**“全部公网”档，默认关，用户自己打开，打开前提示风险。内网、元数据、服务机自身和部署禁段照样拒绝；端口、配额、
   日志规则不变。
3. 每实例同时 4 条隧道，每天 100 MiB 双向流量（按北京时间自然日），超了当天拒绝新隧道。
4. 访问日志保存 6 个月，到期删除，限制读取。

数值可以按被限次数和实际任务完成率再调。

放量前须在东京 VPC 用真实 Pod 验证：允许域成功；撤权终止已打开的长连接；同租户不同实例和重用 Pod IP 的旧令牌被拒；混合公网/内网 DNS 与重绑定被拒；元数据、IPv6 映射、直连 TCP/UDP、SSH 和公网 DNS 被拒。代理停机时模型网关仍可用，抓包确认没有直连回退。两副本同时申请最后一份配额只放行预算内字节。分别用五个锁定模板跑断网冒烟和受控访问，保存版本、请求目标、拒绝原因及代理字节计数，再启用第一批实例。

## 实现状态（2026-11-04）

第一版代码写完，本机测试都过；**东京集群上还没开、没实测**（见下面“上线前”）。提交：`12b61df`（档位、额度、日志、接口）、
`a2f9556`（代理）、`1364d47`（agent 一侧、查询接口、日志到期删除）、`3e71acf`（client-core）、`165c18c`（安卓绑定）。

**选型。** 没用 Smokescreen，代理写在模型网关进程里（`crates/llm-gw/src/egress.rs`，`--egress-listen` 第二个端口）。
原因：沙箱令牌的核对（签名、来源地址、实例在运行、沙箱和代数、授权没吊销）、目录缓存、主机网络的部署都是现成的，用
Smokescreen 还得用 Go 写一层认实例、查档位、记额度的插件，再多部署一个程序。防 SSRF 的地址判断和模型网关共用
`crates/llm-gw/src/ssrf.rs`。

**一条隧道怎么走。**

1. agent-shim 收到 `--egress-proxy 10.0.1.10:8791`（`[sandbox] egress_proxy`）后，给 agent 设
   `http(s)_proxy`、`HTTP(S)_PROXY`、`YARN_HTTP(S)_PROXY`。值是 `http://thinktin:<沙箱令牌>@10.0.1.10:8791`。
   同时设 `no_proxy` / `NO_PROXY`（本机加模型网关的 IP）和 `NODE_USE_ENV_PROXY=1`。没配就什么都不设，和以前一样只连模型。
2. 代理只收 `CONNECT host:443`，别的方法回 405。下面的检查从便宜到贵：
   - 令牌，在 `Proxy-Authorization: Basic` 的密码里，核对和模型请求一样。不对回 407。
   - 每个实例每分钟 120 次。
   - 网站名，用 `proto::egress::normalize_host` 整理：不收 IP、数字变形、单段名字。
   - 端口。
   - 档位（`EgressMode::allows`），不放行回 403。
   - 同时 4 条，再开回 429。
   - 先从今天的额度里预留 256 KiB，没有了回 429。
   - 自己解析，任何一个地址不是公网地址、或者在 `--egress-deny` 里就拒绝，再直接连检查过的地址。
3. 转发时每读到一块先扣额度，不够了再预留。预留在 `egress_usage` 的行锁下做，多副本合计也不会超；隧道结束时退回没用完的。
4. 开着的隧道每 30 秒重新核对一次令牌和档位：实例停了、授权吊销、用户改小了档位就断开。空闲 5 分钟、开满 1 小时也断开。
5. 每条隧道写一行 `egress_log`，放行的和拒绝的都写；每个实例每分钟最多记 30 条拒绝，多的只计数。日志只有元数据：实例、
   网站、端口、连上的地址、结果、字节、时长。保留 183 天，用量行保留 60 天，由后台的例行清理删除。指标有
   `thinktin_egress_tunnels_total{result}`、`thinktin_egress_bytes_total{direction}`、`thinktin_egress_open_tunnels`。

**接口和客户端。**

- `PATCH /v1/instances/{id}` 收 `egress: {mode, hosts, accept_risk}`。`all` 必须带 `accept_risk: true`，App 先提示风险。
  网站整理写法、去重，最多 50 个；`custom` 至少一个。改了记审计 `instance.egress`。
- `GET /v1/instances/{id}/egress` 返回：档位、网站、开发网站预设、今天的用量和上限、同时连接上限、最近被拒绝的访问
  （给“要不要放行这个网站”用）。
- client-core 的 `Instance.egress_mode` 是字符串，以后加档位老 App 不会解析失败；另有 `egress_hosts`、
  `set_instance_egress`、`instance_egress`。

**还没做（有意留到后面的）。**

- 东京集群实测（第 3 节“放量前须在东京 VPC 用真实 Pod 验证”那一串）。在这之前 Tokyo 配置虽然写了
  `egress_proxy` 和 `--egress-listen`，安全组没放 8791 就连不上，agent 照样只连模型。
- 同时 4 条的上限按副本各自计数；现在模型网关只有一个副本，以后多副本要换成共享计数。每天的流量本来就是共享的。
- 隧道不看 TLS 里的 SNI，所以同一个 CDN 上的别的网站拦不住（第 3 节第 5 条已说明）。
- 保险箱按域名注入凭据、HTTP 明文 80 端口、Cube 后端：Cube 出网按节点 SNAT，来源地址对不上令牌，和模型网关一样要先解决身份。
- App 界面（12.x / 13.x）：实例设置里的档位、网站列表、“全部公网”的风险提示、被拒绝的网站一键放行、今天的用量。

## 上线前（在东京打开）

1. 用 `deploy/aliyun/network.py` 给服务机安全组加 8791（只许 VPC 网段）。这一步免费，要在能连阿里云接口的地方跑。
2. 发新版本：模型网关带 `--egress-listen=0.0.0.0:8791`（Tokyo overlay 已经加了），控制面的 `server.toml` 带
   `egress_proxy = "10.0.1.10:8791"`（已经加了）。
3. 用真实 Pod 跑第 3 节的验收：允许的网站能连；默认档拒绝；元数据 100.100.100.200、VPC 里的地址、内网 DNS 名都拒绝；
   撤权以后开着的隧道断开；换了沙箱的旧令牌被拒；用完 100 MiB 当天拒绝。日志和用量对得上。
4. 五个模板各跑一次：装一个 npm 包、一个 pip 包、`git clone` 一个 GitHub 仓库，看代理日志。

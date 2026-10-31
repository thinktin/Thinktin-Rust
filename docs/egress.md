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

建议既有实例继续“只连模型”，新实例显式选择“开发网站”或“自定义网站”。内测不提供“全部公网”自助开关。内测建议每实例 4 条并发、每日 100 MiB 双向流量；从被限次数和实际任务完成率调参。访问日志建议按 6 个月规划容量，限制读取、到期删除；最终保留政策由上线主体确认。这些数值是待批准的配置建议。

放量前须在东京 VPC 用真实 Pod 验证：允许域成功；撤权终止已打开的长连接；同租户不同实例和重用 Pod IP 的旧令牌被拒；混合公网/内网 DNS 与重绑定被拒；元数据、IPv6 映射、直连 TCP/UDP、SSH 和公网 DNS 被拒。代理停机时模型网关仍可用，抓包确认没有直连回退。两副本同时申请最后一份配额只放行预算内字节。分别用五个锁定模板跑断网冒烟和受控访问，保存版本、请求目标、拒绝原因及代理字节计数，再启用第一批实例。

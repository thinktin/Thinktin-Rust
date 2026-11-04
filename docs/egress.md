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

**用户 2026-11-04 再补充（说的是两件事）：**

1. **默认启用联网搜索**：五种 agent 默认就能联网搜索，不弹窗、不用设置。（要核对每种 agent 的搜索工具在我们这里是不是真的
   能用：有的走模型厂商的服务端搜索，有的要搜索服务的 key，见本页第 1 节。）
2. **浏览器权限按上面第 2、3 条执行**：agent 的浏览器打开一个网站时弹授权（访问一次 / 一直允许），页面里顺带加载的字体、
   图片、脚本这些不再一个个问。实现方案写进 [浏览器](browser.md)“实现设计与验收”。

**用户 2026-11-04 改了主意（以这一段为准，下面第一次拍板里的档位开关作废）：**

1. 不要单独的“能上哪些网站”开关。默认就能联网**搜索**，常用**开发网站**（装软件包、拉代码：npm、PyPI、GitHub 等）也默认
   能用，都不弹窗。
2. 别的网站：agent 第一次访问时**弹窗问用户**，三个选项：
   - **访问一次**：只在当前这次任务里能访问，任务结束就失效；
   - **一直允许**：这个 agent 以后都能直接访问，设置里可以撤销；
   - **拒绝**：这次任务里不再问。
3. 用户还没点的时候，先等 1 分钟。这期间同意了就接着访问；没回应就告诉 agent“在等用户同意，先做别的”，用户之后同意了，
   agent 再试就能访问。
4. 不变的：内网、元数据地址、服务机自己哪种情况都连不了；每实例同时 4 条、每天 100 MiB；日志 6 个月。

**用户 2026-11-04 第一次拍板（档位开关部分已作废）：**

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

1. agent-shim 从环境变量 `THINKTIN_EGRESS_PROXY=10.0.1.10:8791`（`[sandbox] egress_proxy`，走环境变量是为了沙箱里还是
   老版本 shim 时照样能起来）拿到地址后，给 agent 设
   `http(s)_proxy`、`HTTP(S)_PROXY`、`YARN_HTTP(S)_PROXY`。值是 `http://thinktin:<沙箱令牌>@10.0.1.10:8791`。
   同时设 `no_proxy` / `NO_PROXY`（本机的各种写法：localhost、127.0.0.1、::1、0.0.0.0、::、主机名、本机地址，加上模型
   网关的 IP）和 `NODE_USE_ENV_PROXY=1`；npm、pnpm、yarn、uv 的并发连接数压到 4（`npm_config_maxsockets` 等），和代理每个
   实例同时给的隧道数一样。没配就什么都不设，和以前一样只连模型。
2. 代理只收 `CONNECT host:443`，别的方法回 405。下面的检查从便宜到贵：
   - 令牌，在 `Proxy-Authorization: Basic` 的密码里，核对和模型请求一样。不对回 407。
   - 每个实例每分钟 120 次。
   - 网站名，用 `proto::egress::normalize_host` 整理：不收 IP、数字变形、单段名字。
   - 端口。
   - 档位（`EgressMode::allows`）：默认 `dev` 直接放行搜索、开发网站和用户一直允许的；别的网站问用户（见下面“问用户”），
     只连模型档直接回 403。
   - 同时 4 条，满了新的排队等最多 30 秒，等不到回 429。
   - 先从今天的额度里预留 256 KiB，没有了回 429。
   - 自己解析，任何一个地址不是公网地址、或者在 `--egress-deny` 里就拒绝，再直接连检查过的地址。
3. 转发时每读到一块先扣额度，不够了再预留。预留在 `egress_usage` 的行锁下做，多副本合计也不会超；隧道结束时退回没用完的。
4. 开着的隧道每 30 秒重新核对一次令牌和档位：实例停了、授权吊销、用户改小了档位就断开。空闲 5 分钟、开满 1 小时也断开。
5. 每条隧道写一行 `egress_log`，放行的和拒绝的都写；每个实例每分钟最多单独记 30 行，多的按“网站、结果”合并，每分钟写
   一行带次数的（`count`）。日志只有元数据：实例、网站、端口、连上的地址、结果、字节、时长。保留 183 天，用量行保留 60 天，
   由后台的例行清理一批批删到没有过期的为止。指标有 `thinktin_egress_tunnels_total{result}`、
   `thinktin_egress_bytes_total{direction}`、`thinktin_egress_open_tunnels`。
6. 每天的上限、同时几条、按哪个时区切天都只在 `proto::egress` 里（模型网关没有改它们的参数），App 看到的就是执行的。
   隧道开过北京时间零点时，退回前一天剩下的预留，改从当天扣。
7. 停机（发版、重启）时出网端口不再接新连接，开着的隧道以 `shutdown` 结束：退回额度、写日志，最多等 10 秒；再把合并的
   日志写掉。进程被直接杀掉（崩溃、OOM）时，开着的隧道的日志和没用完的预留（每条最多 256 KiB）会丢。

**问用户（2.7e，按用户 2026-11-04 改的规则）。** 提交 `f7db8e7`（库）、`ccd4b3c`（代理）、`cb76ab7`（提醒）、`8040ad9`（接口）、`0861148`（client-core）、`4f4950d`（安卓绑定）、`a1ed4ec`（给 agent 的说明）。

1. 迁移 0034 把档位默认值改成 `dev`，已有实例一起改（出口代理还没在任何地方开过）。`dev` 直接放行
   `proto::egress::SEARCH_HOSTS`（Google、Bing、DuckDuckGo、百度、搜狗、360 搜索、Brave 的搜索页和接口）、`DEV_HOSTS` 和
   `egress_hosts`（用户点过“一直允许”的）。不放能替人抓任意网页的服务（比如 r.jina.ai、Tavily：它的 `/extract` 按给的
   网址抓任意网页），那等于绕过逐个网站问用户；代理只看得到网站名、看不到路径，同一个网站上的搜索接口也一起不放。
2. 不在名单上的网站，代理先强制重读一次实例（用户刚点了“一直允许”时缓存里还没有），还不放行就查
   `egress_requests`：这次任务（实例上正在跑的 agent 运行）里用户答过“访问一次”就放行、答过“拒绝”就回 403
   `user_denied`。没有任务时，答复管一小时。
3. 没答过就登记一条请求：同一个实例、同一个网站同时只有一条在等，后来的任务再问就接着等这条（换成后来的任务）；用户
   刚答过（一分钟内）就用答过的那条，不再问一遍。一次任务最多 5 个网站同时在等（前面的任务没人答的不算，它们还在等，
   用户还能点“一直允许”），回 403 `too_many_asks`；每个实例一小时最多登记 20 条用户没答应的（在等的、拒绝的、过期的；
   答应了的不算），再多的回 403 `ask_rate`。用户刚点了“一直允许”又在设置里删掉的，再访问重新问。今天的流量用完了就不问，直接回
   429 `quota`。然后这个 CONNECT 每秒查一次，最多等 60 秒：用户答应了就接着连（`once` 或 `always`），拒绝了回
   `user_denied`，到时间没答回 403 `pending_approval`，正文告诉 agent“已经问了用户，先做别的，过会儿再试”。每个实例
   最多 8 个连接同时在等，再多的照样登记、马上回 `pending_approval`。等到用户答应以后（或者等名额等了一秒以上）重新读实例、
   再核对一遍令牌：等的时候任务结束了就回 407。客户端等不及断开的，日志记一行 `client_gone`。
4. 后台每 2 秒把新登记的请求发给用户：收件箱和推送，推送种类是 `egress_request`（和审批、保险箱一样高优先级：iOS
   time-sensitive、category `EGRESS_REQUEST`，Android 走审批的通知渠道），目标里带请求 id（`tt.egress_request` /
   `tt_egress_request`）、实例和任务；不发 IM 群。每条提醒一次；还在等的时候换了任务、上次提醒过了一小时以上的再提醒一次。
   用户答了、一天没人答标成过期时，收件箱那条算已读。答过、过期了的请求留 60 天（按回答的时间算）。删了的实例的请求不列、
   答不了、不提醒。
5. 用户答应过的隧道，每 30 秒重新核对时只要档位还问用户就不断（缓存里还没有这个网站也不断）；任务结束（令牌代数变了）、
   改成只连模型时照样断。点了“一直允许”以后又在设置里删掉这个网站，开着的隧道开到任务结束（最多 1 小时）。
6. agent 那边：配了出口代理时，平台工具的说明（MCP `instructions`）里写了这套规矩（很多工具碰到代理的 403 只说“CONNECT
   失败”）。pip 这类自己超时短的工具（pip 默认 15 秒）等不满一分钟就放弃，请求照样在等，用户答应后再试就行。

**接口和客户端。**

- `GET /v1/egress-requests?instance_id=&all=`：在等用户回答的网站（`all=true` 也列答过、过期的），新的在前。
- `POST /v1/egress-requests/{id}/decide {decision: once|always|deny}`：已经答过、过期的回 409；“一直允许”的网站满了（50 个）
  回 422，请求还在等。记审计 `egress.decide`。
- `DELETE /v1/instances/{id}/egress/hosts/{host}`：设置里删掉一个一直允许的网站（只删这一个，不会冲掉同时点的“一直允许”；
  用 PATCH 传整个列表会）。记审计 `instance.egress`。
- client-core：`egress_requests(instance_id, include_answered)`、`decide_egress_request(request_id, decision)`、
  `remove_instance_egress_host(instance_id, host)`，`EgressStatus` 多了 `search_hosts` 和 `pending`，收件箱条目多了
  `egress_request_id`。

- `PATCH /v1/instances/{id}` 收 `egress: {mode, hosts, accept_risk}`。`all` 必须带 `accept_risk: true`，App 先提示风险。
  网站整理写法、去重，最多 50 个；`custom` 至少一个。改了记审计 `instance.egress`。
- `GET /v1/instances/{id}/egress` 返回：档位、网站、开发网站预设、今天的用量和上限、同时连接上限、最近被拒绝的访问
  （给“要不要放行这个网站”用）。
- client-core 的 `Instance.egress_mode` 是字符串，以后加档位老 App 不会解析失败；另有 `egress_hosts`、
  `set_instance_egress`、`instance_egress`。

**2.7e 评审（2026-11-04，安全、库的状态和并发、代理、接口和产品 4 个方面，每个方面一个反驳者核对）。** 成立 14 个问题
（原始结果 [drafts/egress-approval-review.md](progress/drafts/egress-approval-review.md)），都修了：Tavily 能抓任意网页，从默认
搜索里去掉；前面任务没人答的请求占满个数、挡住后面的任务（改成只算这次任务的，另加每小时 20 条）；等待时任务结束了还能
开隧道（答应后重新核对令牌）；过期和回答同时发生时回答被冲掉；同一个网站并发登记、回答和登记撞上时多弹一次；按创建时间
删答过的请求；推送优先级太低（新的推送种类）、推送不带请求 id、答过的收件箱条目一直未读；客户端断开不记日志；流量用完了
还问；删了的实例的请求还列着；“一直允许”被设置页整表保存冲掉（加了删单个网站的接口）；没配代理时说明里也讲上网规矩。
驳回 2 条：PATCH 整表替换的并发问题是原来就有的（新加了删单个的接口绕开）；老服务端没有 `egress_mode` 时 App 显示 dev
（老服务端也没有出网接口，App 不会据此做什么）。

第二轮（只看修复，原始结果 [drafts/egress-approval-review-2.md](progress/drafts/egress-approval-review-2.md)）又找出
4 个小问题，也修了：每小时的条数把用户答应了的也算进去、和“这次任务在等的太多”说的是同一句话（分开成 `ask_rate`）；刚点
“一直允许”又删掉的网站一分钟内还能连；删实例时没把在等的请求标过期、收件箱留着未读；[推送约定](push.md)没写新的推送种类。

**评审（2026-11-04，网络逃逸、认证、额度、兼容 4 个方面，每个方面一个反驳者核对）。** 成立的都修了（`97c83e9`、
`a8b0c1c`、`cc54c61`）：

- 东京要把服务机自己的公网地址写进 `--egress-deny`，不写模型网关不启动；
- 放行的隧道也算日志上限，多的合并；清理一批批删完；
- 核对令牌之前按来源地址限次数；
- 预留由守卫拿着，出错、客户端断开都退回；
- 每次改出网档位都记审计；
- 停机时隧道收尾；
- 名额满了排队，包管理器并发压到 4；
- 认不出的档位按只连模型解析；
- no_proxy 补全本机写法；
- 代理地址改走环境变量；
- 跨零点改扣当天；
- 上限只在 `proto::egress`；
- 注销清掉出网设置。

驳回的：过期令牌查库（按来源地址限次数以后成本有上限）、并发改档位漏审计（已改成每次都记）、老版本 shim 不认参数
（还没发过版，没有老镜像；也已改成环境变量）、拒绝的响应缺 `Connection: close`（客户端照样能重连认证）。

**还没做（有意留到后面的）。**

- 东京集群实测（第 3 节“放量前须在东京 VPC 用真实 Pod 验证”那一串）。在这之前 Tokyo 配置虽然写了
  `egress_proxy` 和 `--egress-listen`，安全组没放 8791 就连不上，agent 照样只连模型。
- 同时 4 条的上限按副本各自计数；现在模型网关只有一个副本，以后多副本要换成共享计数。每天的流量本来就是共享的。
- 隧道不看 TLS 里的 SNI，所以同一个 CDN 上的别的网站拦不住（第 3 节第 5 条已说明）。
- 保险箱按域名注入凭据、HTTP 明文 80 端口、Cube 后端：Cube 出网按节点 SNAT，来源地址对不上令牌，和模型网关一样要先解决身份。
- App 界面（12.x / 13.x）：收到 `egress_request` 推送时弹“访问一次 / 一直允许 / 拒绝”；实例设置里列一直允许的网站（可以
  删）、今天的用量。按用户的规则不放档位开关（接口留着给以后的管理策略）。
- 同一个任务被拒绝后，下一个任务还会再问；定时计划每次跑都问同一个网站会每次弹窗，以后看情况加冷却。
- 等用户回答是每秒查一次库；量大了改成数据库通知。

## 上线前（在东京打开）

1. 用 `deploy/aliyun/network.py` 给服务机安全组加 8791（只许 VPC 网段）。这一步免费，要在能连阿里云接口的地方跑。
2. 发新版本：模型网关带 `--egress-listen=0.0.0.0:8791`（Tokyo overlay 已经加了），控制面的 `server.toml` 带
   `egress_proxy = "10.0.1.10:8791"`（已经加了）。**部署前填** Tokyo overlay 里 `--egress-deny` 的服务机公网地址（现在是
   占位 `SERVICE_MACHINE_PUBLIC_IP/32`，不填模型网关启动时报错）；以后加了负载均衡、别的 EIP 也加进去。
3. 用真实 Pod 跑第 3 节的验收：搜索和开发网站直接能连；别的网站弹提醒，点“访问一次”后接着连上、下一个任务再问；元数据 100.100.100.200、VPC 里的地址、内网 DNS 名、服务机
   自己的公网地址都拒绝；
   撤权以后开着的隧道断开；换了沙箱的旧令牌被拒；用完 100 MiB 当天拒绝。日志和用量对得上。
4. 五个模板各跑一次：装一个 npm 包、一个 pip 包、`git clone` 一个 GitHub 仓库，看代理日志。

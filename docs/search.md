# 默认联网搜索（调研和建议）

> 状态：2026-11-04 调研完，等用户定要不要买搜索接口（第 4 节“要你同意的”）。你 11-04 定的是“默认启用联网搜索：五种 agent 默认就能联网搜索，不弹窗、不用设置”（`docs/egress.md:36`）。这一页汇总了 4 路调研：仓库现状、五个 agent 锁定版本的安装包、模型厂商自带的搜索、付费搜索接口。之后又做了一轮核对：仓库行号逐个查过，几个影响决定的价格和开关也重新到官方页面和源码上看了（第 7 节标 †）。要花钱的东西一样都还没买，等你同意。标“没核实”的，是没实测过或只有二手来源的。仓库行号对应提交 `47e8ef6`。

## 用户 2026-11-04 的决定

1. **搜索服务：DeepSeek 为主、阿里云 IQS 备用。** 用户问“clodex 里用的是哪家便宜的”：clodex（github.com/Shiro836/clodex）是
   让 Claude Code 改用 DeepSeek 或 Codex 订阅的启动器，它的搜索就是 DeepSeek 替 Claude Code 跑的服务端搜索（README：
   “DeepSeek runs Claude Code's server-side search tool on its own engine”），也就是 DeepSeek 搜索，和第一条推荐一样。先花约
   ¥2 小测再定。
2. **花费上限：每月 ¥100，每人每天 50 次。** 到了就停下、提醒用户。
3. **agent 自带的厂商搜索：保留**（不关）。所以网关要记厂商替 agent 搜了几次（第 4 节第 3 步提前做），Claude 自带的
   `WebSearch` 也要免弹窗。厂商替 agent 读网页、不经过出口代理这一点，用户知道后选的保留。
4. **Claude 读网页：在 Claude 那层放行**（`WebFetch` 免批准），只留出口代理那一次问用户。

## 实现状态（2026-11-04）

本机测试都过，东京还没部署，也还没有搜索接口的 key。

- **平台搜索工具 `web_search`**（`crates/orchestrator/src/search.rs`）：后台副本调搜索接口，按 `[search].providers` 的顺序
  试（默认 DeepSeek，出错换 IQS），只回标题、链接、网站、日期和最多 300 字的摘要，不要正文（DeepSeek `need_content: false`、
  不用 `summary`；IQS 不要 `mainText`、`summary`）。搜索词最长 128 字，里面有用户保险箱的值就不搜。
- **上限**（`store::search`，迁移 0036 的 `search_usage`）：每人每天 50 次、全站每月 ¥100，先按最贵的一家预留、搜完按实际改
  （都出错的不算次数；DeepSeek 没结果不收钱）。用完了告诉 agent 明天再搜 / 这个月的额度用完了；月度用完时打错误日志，
  指标 `thinktin_search_month_spend_yuan`（这个月花了多少元）、`thinktin_search_calls_total{result,backend}`，运维据此告警。
- **默认给所有实例**：加进默认平台工具，迁移 0036 也加进已有的授权。只读（MCP `readOnlyHint`），Codex 默认不问；Claude 在
  `settings.json` 里放行了 `mcp__thinktin__web_search`。没配 key 时不给这个工具（启动时打一条警告）。
- **Claude 的设置**（`crates/agent-shim/src/config.rs`）：放行 `WebSearch`、`WebFetch`、平台搜索，`skipWebFetchPreflight`。
- **key**：`THINKTIN_DEEPSEEK_SEARCH_KEY`、`THINKTIN_IQS_API_KEY`，只放后台副本的 Secret（docs/release.md 第 5 节）。
- **Pi、OpenClaw 也拿到平台工具**（`config::inject_mcp`）：它们不支持按会话给 MCP 服务器，shim 把桥写进它们自己的配置。
  Pi 写 `~/.pi/agent/mcp.json`，`exposure: direct`（模型才看得见），桥带 `--only web_search`：Pi 没有权限系统，先只给搜索。
  OpenClaw 写 `openclaw.json` 的 `mcp.servers`。

- **厂商替 agent 搜了几次**（用户选了保留厂商自带的搜索）：模型网关从 Anthropic 协议的
  `usage.server_tool_use.web_search_requests`（Anthropic、DeepSeek）和 Responses 输出里的 `web_search_call` 数出来，记进
  `usage_records.web_searches`（迁移 0037），用量看板（`GET /v1/usage`、client-core 的 `UsageBucket.web_searches`）看得到；
  指标 `thinktin_llm_vendor_web_searches_total{vendor}`。通义的 `x_tools`、豆包的 `tool_usage` 还没接（字段名要拿真 key 确认）。

**还没做：**

- 用户买接口、充值、把 key 放进环境变量后：50 个中英文问题的小测，东京连通测试，五个 agent 逐个验收。
- Codex 对不支持搜索的厂商也发 `web_search` 工具，会不会每轮都报错（要拿真 key 试）。
- App 里显示平台搜索今天用了几次、厂商搜索的次数（接口已经有）。

## 1. 现状

**一句话：东京还没部署（服务机还没买，`docs/progress/claude-determined-lovelace-vn0j5h.md:14`），所以下面说的是“按现在的代码上线会怎样”。结论是五个 agent 没有一个能做到“默认能搜、不弹窗”。** Codex 配上支持搜索的厂商能搜，也不弹窗，但用的是厂商替它搜、替它读网页，这一点绕过了“别的网站要问用户”。Claude 能搜，但大概每次都要弹窗。Pi、OpenClaw、Hermes 都搜不了。

几条共同的原因：

- **沙箱现在上不了网。** ACS 建沙箱时关了公网，只放行模型网关（`crates/sandbox/src/acs.rs:368-378`）。出口代理的代码已经做完，但东京还没打开：安全组还没放 8791 端口，服务机也还没买（`docs/egress.md:184-185`，`docs/progress/claude-determined-lovelace-vn0j5h.md:11,14`）。搜索网站名单 `SEARCH_HOSTS` 已经写好。代理打开后，默认档位里名单上的网站不弹窗（`crates/proto/src/egress.rs:23-39`，`crates/proto/src/domain.rs:556-571`）。
- **我们没给任何 agent 配搜索工具，也没有任何搜索服务的 key**（`crates/agent-shim/src/config.rs` 全文都没有）。
- **模型网关把请求原样转给厂商，只改模型名**（`crates/llm-gw/src/body.rs:1-6`）。所以 agent 自带的“厂商替它搜”会直接到用户自己的厂商，费用记在用户的 key 上。
- **网关只记 token，不记搜索次数**（`crates/llm-gw/src/usage.rs:33-38,186-222`）。这笔钱用户在我们 App 里看不到，每天的用量上限也管不住。厂商替它搜也不经过出口代理，出口日志里没有记录（`docs/egress.md:10`）。
- **厂商替它搜，等于厂商替它读网页。** Anthropic 会把搜到的内容放进模型上下文，按输入 token 收费。OpenAI 的搜索可以打开网页、在网页里找内容（`open_page`、`find_in_page`）。DeepSeek 说 Claude Code、Codex 发来的服务端工具调用会用到它的 Search 和 Fetch 接口。这些都不经过出口代理，也不问用户，和 11-04 定的“别的网站要问用户”对不上。
- **我们的平台工具（MCP 桥）现在只给 Claude、Codex、Hermes**，Pi 和 OpenClaw 还没有（`pi.toml:23`，`openclaw.toml:27`）。实测里，Claude 和 Codex 调平台工具前都要用户批准，Hermes 不用（`docs/agent-integration.md:105-108`）。Codex 要批准是因为我们的桥给工具时没带“只读”标记：`tools/list` 只发名字、说明和参数（`crates/agent-shim/src/bridge.rs:310`，`crates/proto/src/shim.rs:63-69`）。见第 6 节。
- **给 agent 的说明写错了。** 平台工具的说明告诉 agent“搜索通常能直接用”（`crates/agent-shim/src/bridge.rs:45`），现在这句不对。

| Agent（锁定版本） | 自带搜索吗 | 谁去搜、谁付钱 | 现在能用吗 | 为什么 |
|---|---|---|---|---|
| **Claude Code** 2.1.296 | 有：搜索 `WebSearch`，读网页 `WebFetch` | 用户的模型厂商去搜，钱算在用户的 key 上 | 看用户用哪家。**Anthropic、DeepSeek 能**：官方文档写了；DeepSeek 用 flash 模型时能不能搜没核实。**豆包**要用户先去控制台开通。**通义（阿里百炼）大概不行**：文档只写了工作空间专属地址，还要求请求里带 `cc_entrypoint=cli`，我们用的是通用地址（`vendors.rs:146,160`），没核实。**MiniMax 没核实。** **Kimi、智谱按量付费、文心的文档里都没有**，大概不能：Kimi 的 Anthropic 接口只收自定义工具，智谱和文心没写。这三家都没实测。混元、阶跃、xAI 没查 | ① 每次搜索大概都会弹窗问用户（没实测）。它被算成“fetch”类工具，默认什么都没有预先允许，没列的就问（`claude_cli.rs:592`，`domain.rs:391-393`，`exec.rs:125-126`）。② 读网页前，它会先把网站名发给 `api.anthropic.com` 查一下，不管用户用哪家模型都这样。这个网站不在名单里，所以会再弹一次窗，或者直接失败。要关掉得写 `skipWebFetchPreflight: true`，我们没写（`config.rs:163-187`）。③ 厂商不支持搜索时，是报错还是空着回答，没核实 |
| **Codex** 0.160.1 | 有：厂商托管的 `web_search` | 厂商去搜，用户付钱 | 默认就发给厂商，**不弹窗**。我们是只读模式，所以它用的是“缓存搜索”。OpenAI 能。DeepSeek 只有 v4-pro 能，flash 会忽略。通义列出的模型能。Kimi 的文档写了支持，但只有 kimi-k3 能用 Responses 接口，而且缓存模式也会实时搜。智谱大概能（没核实）。豆包没开通会报错 | 我们没设 `web_search`，它对每一家厂商都发这个工具（Codex 源码；`config.rs:189-219`）。厂商不认这个工具时，可能每一轮都失败（没核实） |
| **Pi** 1.2.0 | 没有 | — | 不能 | 自带工具只有读、写、改文件和命令行。它其实支持 MCP（在 `~/.pi/agent/mcp.json` 里配置），我们文档里“Pi 本身没有 MCP”这句过时了（`docs/agent-integration.md:152`）。我们还没给它接平台工具 |
| **OpenClaw** 2026.10.3 | 有 `web_search`，但要选一家搜索服务 | 在沙箱里调搜索服务 | 不能 | 没配搜索服务，也没 key（`config.rs:276-343`）。不要 key 的 DuckDuckGo 插件不会被自动选上，而且得在做镜像时就装好，因为运行时禁止装插件（`config.rs:329`）。它自带的 OpenAI 搜索对我们的网关地址不起作用 |
| **Hermes** 0.19.0 | 有 `web_search`、`web_extract`，要搜索服务 | 在沙箱里调搜索服务 | 不能 | 没配任何搜索服务，所以这两个工具直接藏起来了（`config.rs:352-395`）。不要 key 的 `ddgs` 没装。装上它也会去好几个不在名单里的搜索网站，一样会弹窗 |

## 2. 几种做法

- **A. 平台搜索工具（建议）。** 在我们服务器上加一个 `web_search` 平台工具，经 MCP 桥给五个 agent 用。后面接一家付费搜索接口，钱由我们出。
- **B. 厂商自带搜索。** 用 agent 自己带的搜索，由用户的模型厂商去搜，钱由用户的 key 出。B 还有个加强版：让网关按厂商往请求里加搜索参数，这样 Pi、OpenClaw、Hermes 也能用上。但这会打破网关“只改模型名”的规矩（`docs/llm-gateway.md:66`），豆包、Kimi、DeepSeek、OpenAI 的 Chat 接口也加不了，所以不展开。
- **C. 用用户的 key 调厂商的单独搜索接口。** 形式和 A 一样，是平台工具，但拿用户自己的 DeepSeek、Kimi 或智谱 key 去调这几家的搜索接口。
- **D. 让 agent 自己去搜索网站。** 出口代理打开后，必应、百度、谷歌、DuckDuckGo 这些名单里的网站不弹窗。给 OpenClaw 装 DuckDuckGo 插件，给 Hermes 装 `ddgs`，别的 agent 用命令行抓搜索结果页。

| | A 平台搜索 | B 厂商自带 | C 用户 key 调厂商搜索接口 | D agent 自己上搜索网站 |
|---|---|---|---|---|
| 五个都能用吗 | 能。Pi、OpenClaw 要先把桥写进它们自己的配置 | 只有 Claude、Codex，还看用户用哪家 | 能，但只限用 DeepSeek、Kimi、智谱的用户，其他人还得靠 A | OpenClaw、Hermes 装插件后能；Claude、Codex、Pi 不会主动去抓搜索页 |
| 弹窗 | 搜索本身可以不弹，要让 Claude、Codex 对这个工具免批准（第 6 节） | Codex 不弹；Claude 大概弹 | 同 A | 名单里的网站不弹；`ddgs` 会去名单外的网站，会弹 |
| 会不会绕过“别的网站要问用户” | 不会：只给标题、链接、摘要 | **会**：厂商替 agent 读网页正文，不经过出口代理 | 不会：只取摘要的话 | 不会：只上名单里的搜索网站 |
| 谁出钱 | 我们 | 用户的 key（我们 ¥0） | 用户的 key（我们 ¥0） | ¥0 |
| 中文质量 | 选国内厂商，应该不错（没实测） | 看厂商 | 看厂商 | 抓网页拿结果，忽好忽坏 |
| 稳不稳 | 稳，是正式接口 | 看厂商。不支持的会报错，豆包要用户自己去开通 | 稳 | 不稳：插件是非官方的，东京机房的 IP 可能被验证码拦（没核实） |
| 我们管得住吗 | 能：记次数、设上限、只给标题和摘要 | 现在管不住：不记次数，费用用户看不到，也不经过出口代理 | 能 | 只能按流量管（算在每天 100 MiB 里，`egress.rs:54`） |
| 要等出口代理吗 | 搜索本身不用等，是服务器去搜的；agent 要打开结果网页还得等 | 不用 | 不用 | 要 |
| 主要缺点 | 要花钱、要你同意；用户的搜索词会交给第三方 | 覆盖不全；豆包要开通，违反“不用设置”；绕过逐站审批 | 用户的 key 拿来搜索之前要先告诉用户；从网关拿用户 key 的做法还要再看 | 可能违反搜索网站的条款，结果不稳定 |

## 3. 钱

**假设：** 每个活跃用户每天搜 20 次，这个数估得偏高。每月就是 10 人 6,000 次、100 人 6 万次、1000 人 60 万次。美元按 ¥6.72 换算，这是 2026-10-16 的人民币中间价，来自二手来源，11 月的没查到。每月都有的免费额度已经扣掉，一次性的试用额度没扣。

**我们出的钱（做法 A，按搜索接口算）：**

| 搜索接口 | 单价 | 10 人/月 | 100 人/月 | 1000 人/月 |
|---|---|---|---|---|
| DeepSeek 搜索 † | ¥5/千次（国际站 $0.75），只算成功的请求，没有免费额度 | ¥30 | ¥300 | ¥3,000 |
| 百度搜索促销价（到 12-31，只有二手来源，没核实） | ¥4.9/千次 | ¥29 | ¥294 | ¥2,940 |
| 阿里云 IQS（LiteBasic）† | ¥8/千次 | ¥48 | ¥480 | ¥4,800 |
| 智谱 `search_std` † | ¥10/千次 | ¥60 | ¥600 | ¥6,000 |
| Kimi Basic（官方价目表是网页脚本渲染的，读不出数字，没核实） | 约 ¥10/千次 | ¥60 | ¥600 | ¥6,000 |
| Perplexity 快速档 † | $1/千次 | ¥40 | ¥403 | ¥4,032 |
| 腾讯元宝搜索（最快档） | ¥14/千次 | ¥84 | ¥840 | ¥8,400 |
| 百度搜索标准价（每月 1,500 次免费） | ¥36/千次 | ¥162 | ¥2,106 | ¥21,546 |
| Brave（每月 $5 免费） | $5/千次 | ¥168 | ¥1,982 | ¥20,126 |
| Tavily | $8/千次起 | 约 ¥269 | 约 ¥2,661 | 约 ¥30,240 |

- **对比：** 现在整个服务器预算是每月 ¥390–450（`docs/deploy-aliyun-sg.md:190`），搜索费要在这之外另算。10 个用户的搜索费是 ¥30–60，大约多出服务器钱的 7–15%。到 100 人时搜索费是 ¥300–600，和现在整台服务器的钱差不多。
- **上限：** 建议每人每天最多 50 次。按 DeepSeek 的价格，每人每月最多 ¥7.5；10 人最多 ¥75，1000 人最多 ¥7,500。如果切到备用的 IQS，10 人最多 ¥120，会超过下面建议的每月 ¥100，所以到了总额就停或者提醒你。
- **服务器：** 每次搜索只是服务机发一个很小的请求。计划买的 2 核 4G 服务机（`docs/deploy-aliyun-sg.md:182`）应该够用（估计，没实测）。
- **国外接口：** Brave、Tavily、Exa 比国内贵 3–10 倍。Perplexity 快速档（$1/千次）、Serper（$0.3–1/千次）、Cloudflare 转接的 Ceramic（$0.25/千次，调研员读的官方页面，我没重读）不贵。但它们都要把国内用户的搜索词发到美国公司，中文质量也没测过。

**用户自己的 key 出的钱（我们 ¥0，但现在网关不记，用户看不到）：**

| 情况 | 用户付多少 |
|---|---|
| Claude + Anthropic † | 每千次搜索 $10，另加搜到内容的 token。Claude 一次搜索最多会搜 8 次，所以一次最多约 $0.08（约 ¥0.54） |
| Claude 或 Codex + DeepSeek † | 每千次 ¥5（国际站 $0.75），11-01 北京时间零点起开始收 |
| Codex + OpenAI | 每千次 $10，另加搜到内容的 token（缓存搜索是不是同价，没核实） |
| Codex + 通义 † | 北京、东京、香港、弗吉尼亚每千次 ¥4，**新加坡每千次约 ¥73**，另加内容 token。我们的 `qwen-intl` 用的就是新加坡的地址（`vendors.rs:160-163`），而你 10-27 定的是国内厂商走国际站（`docs/deploy-aliyun-sg.md:12`） |
| Codex + 智谱 | 国内站每次 ¥0.01–0.05（在 Responses 接口里怎么收，没核实）；国际站 Z.ai 每次 $0.01（调研员读的，我没重读） |
| Codex + Kimi † | 实际搜一次算一次，单价读不出来（没核实） |
| Codex + 豆包 | 要先开通。联网内容插件每月 2 万次免费，之后每千次 ¥4 |
| 做法 A 的平台搜索 | 搜索费我们出。用户只付读搜索结果的 token：每次约 10 条、每条约 300 字，大约几千 token（估计） |

## 4. 建议

**以平台搜索（做法 A）为主，先买一家国内搜索接口。agent 自带的厂商搜索在平台搜索上线时关掉。以后要不要按厂商再打开，等你定，因为它会绕过逐个网站问用户。** 理由：

1. 五个 agent 都要“默认能搜、不弹窗、不用设置”，只有 A 做得到。B 只覆盖两个 agent，还看用户用哪家；D 不稳定。要做完第 2 步、在东京逐个验收过，才算真的做到。
2. 钱有数：10 人每月约 ¥30–60，加上每人每天的上限，最坏情况也算得出来。
3. 搜索服务的 key 放在我们服务器上，不进沙箱，守住“真 key 不进沙箱”的规矩（`config.rs:3`）。只返回标题、链接、摘要，不替 agent 抓整页，所以不会绕过“别的网站要问用户”这条规矩（`egress.rs:19-22`）。
4. 搜索本身不用等出口代理在东京打开。
5. 我们能记次数、看用量、设上限。

**买哪家：先小测再定。** 建议主用 DeepSeek 搜索，备用阿里云 IQS。

- **DeepSeek 搜索：** 国内正式价里最便宜，每千次 ¥5。官方页面没写哪天开放，二手报道说是 10-17。通过 Claude Code、Codex 调的从 11-01 起收费。中文质量还没人测过。从充值余额里扣，所以要先充值；最低充值额、实名和付款要求都没核实。返回的 `snippet` 一般 100–200 字；另外还有 600–800 字的 `summary`，打开 `need_content` 时还有正文，这两样都要丢掉。
- **阿里云 IQS：** 每千次 ¥8，默认每秒 10 次。钱记在我们现有的阿里云账单上，实名已经做过，不用新开一家供应商。LiteBasic 的接口名是 `CNLiteBasic`，英文网站搜得怎么样不知道；国际版 GlobalAdvanced 每千次 ¥56。免费试用官方页面没写（没核实）。
- **小测结果不好时：** 改用智谱 `search_std`（每千次 ¥10）或 Kimi Basic（价格没核实）。
- **不建议用的：**
  - Brave、Tavily、Exa：贵，还要把国内用户的搜索词发到美国公司。Perplexity 快速档便宜，但也是美国公司，没有免费额度。
  - Serper：抓的是谷歌的结果。谷歌 2025-12 起诉过同类服务 SerpApi，据二手报道 2026-07 被驳回、可以修改后再告，后来有没有再告没核实。
  - Google 的官方接口不再接新客户；必应的接口 2025-08-11 已经下线。
  - Jina 搜索：默认把前几条结果的整页正文一起给，会绕过逐站审批。

**分步：**

1. **第 0 步（不花钱，不用你同意）：**
   - 给 Claude 写一个 `settings.json`（放在 `CLAUDE_CONFIG_DIR` 下），加上 `skipWebFetchPreflight: true`。这样读网页前不再先去问 `api.anthropic.com`。副作用是不再查 Anthropic 的网站黑名单，但哪些网站能连本来就由出口代理管。
   - 改掉平台工具说明里“搜索通常能直接用”那句（`bridge.rs:45`），等真能用了再改回来。
   - 改正文档：Pi 1.2.0 支持 MCP（`docs/agent-integration.md:152`）。
   - 用测试 key 看一下 Codex 在每家 Responses 厂商上会不会因为搜索工具报错（只花一点 token 钱）。会报错的，先对那家设 `web_search = "disabled"`。
2. **第 1 步（要你同意：注册接口、少量充值）：小测。**
   - 准备 50 个中英文问题，让 DeepSeek、IQS、智谱、Kimi 各跑一遍。
   - 一共约 200 次调用，按单价算大约 ¥2。DeepSeek 要先充值，有的厂商可能有最低充值额，没核实。
   - 顺便从东京测一下能不能连上、快不快，到现在只从美国测过，能连上。东京的服务机还没买，ACS 沙箱又不能上公网，所以要么等服务机买了再测，要么临时开一台按量计费的 ECS 测一小时（约 ¥0.25/小时加流量，也要你同意）。
3. **第 2 步（要你同意每月预算）：做平台 `web_search`。**
   - 服务器调搜索接口，只回标题、链接、网站名、日期和约 300 字的摘要，正文、长摘要、百度的直答卡片都丢掉。
   - 默认给所有实例：新领养的加进默认工具（`crates/server/src/config.rs:136-148`），已有的写数据库迁移，照 `crates/store/migrations/0026_ask.sql:15-21` 的做法。
   - 不弹窗：
     - Codex：给这个工具加 MCP 的“只读”标记（`readOnlyHint: true`）。要在 `proto::shim::PlatformTool` 和桥的 `tools/list` 里加这个字段（`shim.rs:63-69`，`bridge.rs:310`）。从 Codex 源码看，默认模式下只读工具不用批准（见第 6 节），没实测。
     - Claude：在 `settings.json` 里写 `permissions.allow: ["mcp__thinktin__web_search"]`；命令行模式也可以用 `--allowedTools`。从 ACP 适配器的代码看应该行，没实测。
   - Pi、OpenClaw：把桥写进它们自己的配置，Pi 写 `mcp.json`（用 `direct` 方式暴露，模型才看得见这个工具），OpenClaw 写 `mcp.servers`。Pi 没有权限系统（`docs/agent-integration.md:125`），所以先只给它搜索这一个平台工具。OpenClaw 调 MCP 工具要不要批准，没核实。
   - 关掉 agent 自带的搜索，免得两套重复、免得报错，也免得厂商替 agent 读网页：
     - Claude：`permissions.deny: ["WebSearch"]`。
     - Codex：`web_search = "disabled"`。
     - OpenClaw：`tools.web.search.enabled: false`。它的 `web_search` 默认是开的，只是没有搜索服务，模型可能会去调它然后失败（没核实）。
     - Hermes：没配搜索服务时本来就藏起来了。
   - 每人每天最多 50 次，超了就告诉 agent 明天再搜。每月总额快用完时提醒你。
   - 在东京把五个 agent 逐个验收。
4. **第 3 步（以后，看你的决定再做）：**
   - 如果你同意，再给用户的 key 本身支持搜索、而且实测过的厂商（Anthropic、DeepSeek、OpenAI、通义）打开厂商自带的搜索，钱由用户的 key 出，我们省钱。但这会让厂商替 agent 读网页、绕过逐站审批（第 1 节）。
   - 网关记下厂商替 agent 搜了几次，App 里能看到：Anthropic 和 DeepSeek 看 `usage.server_tool_use.web_search_requests`（Anthropic 文档里写了这个字段 †），通义看 `x_tools`，豆包看 `tool_usage`。后两个字段名要实测确认。只要保留厂商搜索，这一项就要提前到上线前做。
   - App 里显示搜索次数和费用。
   - Claude 自带搜索的弹窗要先解决。
   - 也可以考虑做法 C。

**要你同意的：** 买哪家（建议 DeepSeek 为主、IQS 备用）；小测约 ¥2，加上 DeepSeek 的首次充值；在东京测连通要不要临时开一台按量 ECS；测试期每月搜索预算上限（建议 ¥100，10 人预计 ¥30–60）；每人每天上限（建议 50 次）。

## 5. 工作量估计

都是估计，没实测。

| 内容 | 人天 |
|---|---|
| 第 0 步：Claude 的 `settings.json`、说明文字、文档、Codex 在各家厂商上的试跑 | 0.5–1 |
| 第 1 步：小测脚本和对比 | 0.5–1 |
| 第 2 步：服务器上的搜索工具（调接口、只留摘要、超时、每人每天上限、记事件、默认给和迁移） | 2–3 |
| 第 2 步：桥加“只读”标记，Claude 放行这个工具，三家关掉自带搜索 | 0.5–1 |
| 第 2 步：Pi 接上 MCP 桥 | 1–1.5 |
| 第 2 步：OpenClaw 接上 MCP 桥 | 1–1.5 |
| 第 2 步：东京五个 agent 验收 | 1–2 |
| **第 0–2 步合计** | **约 6.5–11** |
| 第 3 步：网关记厂商的搜索次数并在用量里显示 | 1.5–2 |
| 第 3 步：按厂商打开自带搜索，App 显示费用 | 2–3 |

Pi 和 OpenClaw 接上桥以后，浏览器的方案也用得上（`docs/browser.md` 第 5 节第 2 步），这部分是两边共用的工作。

## 6. 风险和要定的事

- **打开搜索结果还是会弹窗。** 搜索本身不弹窗。但 agent 要读某一篇文章时，那个网站不在名单里，按 11-04 的规矩会问用户：访问一次、一直允许、还是拒绝。很多问题看摘要就够了。另一个办法是“服务器替 agent 读网页”，但那会绕过逐个网站问用户，建议先不做。还有几点：
  - 出口代理在东京打开之前，agent 根本读不了网页。
  - Claude 在默认权限模式下，`WebFetch` 自己也会先要批准（Claude Code 官方工具文档 †），这样一篇文章可能要弹两次窗：一次是 Claude 的，一次是出口代理的。可以考虑在 Claude 的设置里放行 `WebFetch`，只留出口代理那一次，这个要你定。
  - Codex 在只读模式下，用命令行抓网页也要批准。
- **免批准要实测。**
  - **Codex：** 0.160.1 的源码里，MCP 工具有逐个工具的批准方式（`mcp_servers.<名字>.tools.<工具>.approval_mode`，可选 `auto`、`prompt`、`writes`、`approve`，默认 `auto`，见 `codex-rs/config/src/mcp_types.rs:26-34`）。`auto` 模式下，工具带了 `readOnlyHint: true` 就不用批准（`codex-rs/core/src/mcp_tool_call.rs:2466-2496`）。我们的桥没带这个标记，所以现在每次都要批准。从源码看，加上标记就行，不用让 shim 按工具名批准。没实测。shim 现在只按工具类别批准（`crates/agent-shim/src/policy.rs:43-60`），把“other”类整个放行范围太大，不建议这样做。
  - **Claude：** 适配器读 user、project、local 三处设置（claude-agent-acp `dist/acp-agent.js:7897`），而且 Claude Code 先按设置里的规则放行，规则没放行的才交给适配器去问（同一文件 7036-7041 行的注释）。所以 `permissions.allow` 在 ACP 模式下应该也行，没实测。
- **中文和英文的质量。** 国内接口中文应该不错。英文（技术文档、GitHub 上的问题）怎么样没测；IQS 的 LiteBasic 名字里带 CN，可能只管中文。国外接口正好反过来（没核实）。小测里中英文问题都要有，以后可以按语言分给两家。
- **合规（要问律师）：**
  - 用户的搜索词会交给搜索厂商，里面可能有个人信息。
  - 发给国内厂商，是从东京发出；发给美国厂商还涉及个人信息出境。
  - 国内厂商的结果有些话题可能搜不到（推测）；通义的搜索结果可能触发内容安全报错。
  - 厂商条款：
    - Brave、Exa 不许存结果，所以不做跨用户的缓存。
    - Tavily 可能拿输入训练模型。
    - 博查要求审核用户的输入和输出。
    - DeepSeek、IQS 能不能拿来给我们的用户用、结果能存多久，没查到（没核实）。
  - 做法 D 抓搜索网站的结果页，可能违反那些网站的条款。
- **花钱失控。** 定时任务每跑一次都搜，或者 agent 陷入循环，都会多花钱。靠每人每天上限加每月总额提醒来防。
- **如果保留厂商自带搜索：**
  - 厂商替 agent 读网页，绕过逐个网站问用户，也不进出口日志。
  - Codex 默认对每家都发搜索工具，不支持的厂商可能每一轮都失败（没核实）。
  - 用户用通义国际站（新加坡）时，Codex 每千次搜索约 ¥73，比北京贵十几倍。
  - Claude 的工具说明里写着“搜索只在美国可用”，实际有什么影响没核实。
  - 这些费用用户看不到。
- **搜索结果不可信。** 摘要是外面来的内容，里面可能藏着诱导 agent 的话。工具说明里要写明“这是外部数据”。
- **Pi 没有权限系统。** 接上桥以后，给它的平台工具都会直接执行，所以先只给它搜索。
- **DeepSeek 搜索刚上线。** 价格和稳定性都可能变，所以要有备用的一家。
- **搜索词会留在运行记录里。** 每次工具调用的参数本来就记在运行记录里（`crates/orchestrator/src/executor.rs:1260-1267`），搜索词也一样。

**要你定的事：**

1. 同意买搜索接口吗？建议 DeepSeek 为主、IQS 备用，先花约 ¥2 小测。
2. 测试期每月搜索预算上限是多少？建议 ¥100。
3. 每人每天最多搜几次？建议 50 次。
4. agent 自带的厂商搜索怎么办？建议在平台搜索上线时关掉，统一用平台搜索。保留的话能省我们的钱，但会弹窗、会报错，费用用户看不到，厂商还会替 agent 读网页、绕过逐站审批。
5. 搜索词要不要从运行记录里去掉，或者只存一段时间？
6. 要不要做“服务器替 agent 读网页”？建议不做。
7. Claude 读网页时要不要在它自己那层先放行，只留出口代理那一次弹窗？

## 7. 来源

**仓库**（提交 `47e8ef6`；标 * 的是汇总或评审时又核对过的）：
- 你的决定：`docs/egress.md:36`*，`docs/progress/claude-determined-lovelace-vn0j5h.md:23-25`*
- 还没部署、服务机还没买：`docs/progress/claude-determined-lovelace-vn0j5h.md:11,14`*，`docs/deploy-aliyun-sg.md:3`*
- 沙箱断网：`crates/sandbox/src/acs.rs:368-378`*，`deploy/k8s/overlays/tokyo/server.toml:37-41`*
- 出口代理还没打开：`docs/egress.md:184-185`*
- 名单和规矩：`crates/proto/src/egress.rs:7-39,54`*，`domain.rs:556-571`*（默认档位 556-557）
- 预授权默认为空：`crates/proto/src/domain.rs:391-393`*
- 没列的都问用户：`crates/orchestrator/src/exec.rs:125-126`*
- 工具类别：`crates/agent-shim/src/claude_cli.rs:592`*
- 按类别批准：`crates/agent-shim/src/policy.rs:43-60`*
- 配置生成：`crates/agent-shim/src/config.rs:3,163-187,189-219,245-271,276-343,329,352-395`*
- 给 agent 的说明：`crates/agent-shim/src/bridge.rs:45`*；桥发给 agent 的工具定义没带标记：`bridge.rs:310`*，`crates/proto/src/shim.rs:63-69`*
- 默认平台工具：`crates/server/src/config.rs:123,136-148`*；平台工具范围为空就不给：`domain.rs:410-411`*
- 平台工具要不要批准、Pi 没有权限系统、过时的那句：`docs/agent-integration.md:105-108,125,152`*
- 服务器预算和规格：`docs/deploy-aliyun-sg.md:182,190`*；国内厂商走国际站：同文件第 12 行*
- 通义各地域的地址：`crates/proto/src/vendors.rs:144-191`*
- 浏览器方案：`docs/browser.md`*
- 网关原样转发：`crates/llm-gw/src/body.rs:1-6`*，`proxy.rs:535-562,723-773,995-1006`
- 网关只记 token：`crates/llm-gw/src/usage.rs:33-38`*，`186-222,343-365`
- 厂商列表：`crates/proto/src/vendors.rs:82-90`*，`128-460`
- 加平台工具的位置：`crates/orchestrator/src/shim.rs:97-102`，`tools.rs:410-437`，`crates/server/src/workers.rs:141-167`，`crates/store/migrations/0026_ask.sql:15-21`*
- 运行记录：`crates/orchestrator/src/executor.rs:833-850`，`1260-1267`*
- MCP 桥：`pi.toml:23`*，`openclaw.toml:27`*，`crates/agent-shim/src/acp.rs:87-91`，`shim.rs:67-72`

**上游安装包和源码**（调研员 2026-11-04 下载后直接读的内容，没有安装；标 † 的是评审时 11-04 又读过的）：
- claude-agent-acp 0.90.0 / claude-agent-sdk 0.3.296；† `dist/acp-agent.js:7006-7045,7897`
- codex-acp 2.2.2；Codex 源码 `rust-v0.160.1`（提交 d27764b）：https://github.com/openai/codex/tree/rust-v0.160.1 （`core/src/config/mod.rs`、`core/src/tools/spec_plan.rs`、`model-provider/src/provider.rs`；† `core/src/mcp_tool_call.rs:1480-1560,2466-2496`，† `config/src/mcp_types.rs:26-34`）
- pi-coding-agent 1.2.0、pi-acp 0.0.34
- openclaw 2026.10.3、@openclaw/duckduckgo-plugin
- hermes-agent 0.19.0、ddgs 9.16.1

**官方页面**（都是调研员 2026-11-04 读的；标 † 的是评审时 11-04 又读过的）：
- Claude Code：https://code.claude.com/docs/en/tools-reference †，https://code.claude.com/docs/en/data-usage †，https://code.claude.com/docs/en/feature-availability
- Anthropic 搜索工具（价格、`encrypted_content`、`server_tool_use.web_search_requests`）：https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool †
- OpenAI：https://developers.openai.com/api/docs/guides/tools-web-search †（`open_page`、`find_in_page`、`external_web_access`），https://developers.openai.com/api/docs/pricing ；Codex 配置：https://learn.chatgpt.com/docs/config-file/config-reference
- DeepSeek：https://api-docs.deepseek.com/guides/search †，https://api-docs.deepseek.com/zh-cn/quick_start/pricing †，https://api-docs.deepseek.com/guides/anthropic_api
- 阿里云百炼搜索（按地域的价格）：https://help.aliyun.com/zh/model-studio/web-search †；IQS：https://help.aliyun.com/zh/document_detail/2862023.html †，https://help.aliyun.com/zh/document_detail/2871439.html
- 智谱：https://docs.bigmodel.cn/cn/guide/tools/web-search ，https://docs.bigmodel.cn/cn/guide/start/pricing.md †；Z.ai：https://docs.z.ai/guides/overview/pricing
- Kimi：https://platform.kimi.com/docs/pricing/tools †（价目表是空的，只有计费规则），https://platform.kimi.com/docs/api/responses.md ，https://platform.kimi.com/docs/api/messages.md
- 火山方舟：https://docs.volcengine.com/docs/82379/1756990 ，https://docs.volcengine.com/docs/82379/1338550
- 百度千帆：https://cloud.baidu.com/doc/qianfan/s/1mh4sv6c4 ，https://cloud.baidu.com/doc/qianfan-docs/s/Wm8r4sw29
- 腾讯元宝搜索：https://cloud.tencent.com/document/product/1806/121798
- 博查：https://open.bochaai.com/terms-of-service
- Brave：https://brave.com/search/api/ ，https://api-dashboard.search.brave.com/documentation/resources/terms-of-service
- Tavily：https://docs.tavily.com/documentation/api-credits ，https://www.tavily.com/terms
- Exa：https://exa.ai/pricing
- Perplexity：https://docs.perplexity.ai/getting-started/pricing †
- Cloudflare 搜索：https://developers.cloudflare.com/web-search/providers/
- Serper：https://serper.dev/
- Google 自定义搜索不再接新客户：https://developers.google.com/custom-search/v1/overview
- 必应接口已下线：https://learn.microsoft.com/en-us/lifecycle/announcements/bing-search-api-retirement
- Jina：https://jina.ai/reader/
- OpenClaw：https://docs.openclaw.ai/tools/web ；Hermes：https://hermes-agent.nousresearch.com/docs/user-guide/features/web-search/

**二手来源（没核实）：**
- 百度促销价：https://www.drweb.de/baidu-such-api-ki-agenten-preis/ ，https://ithome.com/1/020/165.htm
- DeepSeek 搜索开放日期：https://www.qbitai.com/2026/10/506771.html
- 汇率：https://cj.sina.com.cn/articles/view/1663612603/6328b6bb0200248kg
- 谷歌告 SerpApi：https://www.theregister.com/2026/02/21/serpapi_google_scraping_lawsuit/ ，https://www.gigazine.net/gsc_news/en/20260723-google-loses-lawsuit-against-serpapi

**没核实的（要拿真 key 实测）：**
- 厂商搜索：
  - Claude 搜索在 Kimi、智谱按量付费、通义、MiniMax、豆包、文心上，到底是报错还是空着回答。
  - Codex 的搜索工具发给不支持的厂商时，会不会每轮都失败。
- 免批准：
  - Claude 的 WebSearch 在我们这里会不会弹窗。
  - Claude 的 `permissions.allow` 在 ACP 模式下行不行（代码上看应该行）。
  - Codex 看到 `readOnlyHint` 后是不是真的不再要批准（源码上看是）。
  - OpenClaw 调 MCP 工具要不要批准；它没有搜索服务时 `web_search` 是藏起来还是报错。
- Pi 设了 `PI_OFFLINE=1`，会不会影响 MCP。
- 搜索接口本身：
  - 各家的中文、英文质量。
  - 东京能不能连上、快不快。
  - DeepSeek、Kimi、智谱的实名、付款和最低充值要求。
  - Kimi 的单价。
  - IQS 的免费试用。
  - 百度促销的条款。
  - DeepSeek、IQS 对存结果和给第三方用的条款。
- 网关里通义、豆包搜索次数的字段名。
- Claude 说明里“搜索只在美国可用”的实际影响。

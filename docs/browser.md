# agent 自己的浏览器（调研和建议）

> 状态：调研，2026-10-29，**还没开工、还没定**。用户 10-29 问“agent 要有自己的本地浏览器怎么做？自己开发还是买阿里云的（比如
> 无影 AgentBay）？”。这一页是调研结论（4 路调研、3 个方案各算一遍、再核对一遍官方页面）。价格、规格以第 7 节的官方页面为准，
> 标“估计”的是没实测的。

## 1. 现状

- **agent 现在上不了网**：ACS 沙箱建的时候关了公网，只放行模型网关一个地址（`crates/sandbox/src/acs.rs:367-377`，
  `deploy/k8s/overlays/tokyo/server.toml:35-38`）；出口代理（WBS 2.7）还没做。所以不管买不买，agent 要浏览网页都得先有一条
  受控的出网通道。
- **镜像里没有浏览器**：`deploy/templates/Dockerfile` 没装 Chromium、没装中文字体；沙箱是 1 核 1–2 GB（各 agent 的
  `manifests/*.toml` `[runtime]`）。
- **五个 agent 里只有 OpenClaw、Hermes 自带浏览器工具**（都能接一个现成的 Chromium）；Claude Code、Codex、Pi 要接 MCP 浏览器
  （Playwright MCP）。Claude in Chrome 要用户本地 Chrome 插件加 claude.ai 登录，Codex 的浏览器只在 ChatGPT 桌面版里，都用不上。
- **App 看不到沙箱里的画面**：事件流单条最多 16 KB，截图放不进去；网关不直连沙箱。实时看、接手操作要新做。
- 电脑端（14.x）控制的是**用户自己的电脑**，现在只是打开网址、截屏、点击，没有用 chromiumoxide（那是 14.4 的计划），也还没在
  真 Mac 上跑过。

## 2. 三种做法

| | 自己做：沙箱里装浏览器 | 买：无影 AgentBay 云浏览器 | 混合（建议） |
|---|---|---|---|
| 浏览器在哪 | 每个 agent 自己的沙箱里（东京） | 阿里云的另一台虚拟机里（国内账号在杭州 / 上海） | 默认在沙箱里；要国内 IP 的再接 AgentBay；“以我的身份”用用户自己的电脑 |
| 网站看到的 IP | 东京机房 | 国内账号：大陆（推测，官方没写）；国际账号：新加坡 / 弗吉尼亚 | 东京为主，按需加大陆 |
| 外网（Google、GitHub、ChatGPT） | 能打开 | 大陆打不开（GitHub 部分） | 能 |
| 国内网站（淘宝、小红书、微信、银行） | 小红书等显示“IP 属地 日本”；淘宝、微信、银行可能要验证或拦（论坛反馈，官方没写） | 大陆 IP 更合适 | 走用户自己的电脑或大陆浏览器 |
| 看画面、接手登录 / 验证码 | 自己做（CDP 截帧经网关推到 App） | 现成（`resource_url` 实时画面加键鼠），但要企业实名，2025-10 还是白名单；条款写“限你或你的企业使用”，给终端用户看要阿里书面确认 | 自己做 |
| 滑块验证码、指纹、代理 | 没有（是军备竞赛，不承诺） | 有：只支持滑块；设备指纹要 Ultra | 需要时用 AgentBay |
| 登录状态存哪 | 沙箱工作区里，跟着工作区按用户密钥加密存 OSS | 阿里那边的 Context 存储（不在我们的加密里） | 沙箱里 |
| 出网管控 | 全在我们的出口代理 | 我们管不到（Linux 浏览器不支持出网白名单，`*.aliyuncs.com` 总是放行） | 我们的代理 |
| 门槛 | 先做出口代理（上线前本来就要做） | 让 agent 用 CDP 控制浏览器要 Pro 套餐：¥999/月（国际站 $149/月）；免费的 Basic 不给 CDP | 默认路线没有 |
| 成熟度 | 开源组件成熟（Chromium、Playwright，Apache / MIT） | 2025-07 发布；好几项还是 Beta、文档前后矛盾、没找到 SLA、SDK 还没到 1.0、没有 Rust SDK | — |

## 3. 钱

单价差不多：我们东京沙箱按 ACS Agent Sandbox 海外价 ¥0.1232/核·时、¥0.0616/GB·时（2 核 4 GB ≈ ¥0.49/时）；AgentBay 国内
¥0.12/核·时、¥0.05/GB·时（浏览器镜像规格没公布，按 2 核 4 GB 算 ≈ ¥0.44/时）。差别在 AgentBay 有 ¥999/月的门槛，而我们自己做
是把开了浏览器的沙箱调大。

假设：每个活跃用户的 agent 每天跑 1 小时、其中浏览 20–30 分钟，所有活跃用户都开了浏览器（偏高的估计）。

| 每月 | 10 个测试用户 | 100 个活跃用户 | 1000 个活跃用户 |
|---|---|---|---|
| 自己做，开浏览器的沙箱调到 2 核 4 GB | 约 ¥80 | 约 ¥800 | 约 ¥8,400 |
| 自己做，1 核 3 GB 够用的话 | 约 ¥30 | 约 ¥260 | 约 ¥2,800 |
| 全买 AgentBay 国内（杭州） | 约 ¥1,075（套餐占 93%） | 约 ¥1,600–1,760 | 约 ¥6,700–8,600 |
| 全买 AgentBay 国际（新加坡） | 约 $166 | 约 $280–320 | 约 $1,440–1,860 |

- 自己做的数字取决于 Chromium 到底要多少内存（没实测，空闲时约 700 MB）。第一步就是在东京 ACS 上量一下。
- 到 1000 个活跃用户、又确实要 2 核 4 GB 时，AgentBay 国内的计算费会和自己做差不多甚至略低；但它是大陆 IP，打不开外网，不是
  同一种东西。
- 网页流量是进方向，阿里云不收；看画面的流量约 ¥0.5/人·月。模型 token 按用户自己的 key，浏览很费 token。

## 4. 工作量（估计）

| | 人天 |
|---|---|
| 自己做 A 阶段：agent 能浏览公开网页（出口代理约 11.5 天，上线前本来就要做；镜像、启动 Chromium、给五个 agent 接 Playwright MCP、开关和规格、实测） | 约 32–35 |
| 自己做 B 阶段：App 里实时看、接手登录 / 验证码、保险箱密码代填（不让模型看到） | 约 22–27 |
| 全买 AgentBay：接口客户端、浏览器工具、接手流程、App 里的 WebView、用量上限、实测 | 约 41（另有可选约 7.5） |
| 混合里后加的“大陆浏览器”（AgentBay） | 约 10，外加 ¥999/月 |

买也省不了多少：浏览器工具、接手流程、App 界面两边都得做，买只省掉“自己做实时画面”和验证码、指纹这些。

## 5. 建议

**自己做为主，AgentBay 先不买，留作以后的“大陆浏览器”。** 理由：

1. AgentBay 没有东京；国内账号只能在大陆跑（打不开 Google、ChatGPT），国际账号是另一个账号（之前的国际账号卡在实名）。
2. 让 agent 控制浏览器起步就要 ¥999/月，测试阶段是现在整个服务器预算（¥390–450/月）的两倍多。
3. 单价和我们自己的沙箱差不多，买不省用量的钱；工作量也只少一点。
4. 出口代理上线前本来就要做（威胁模型里排第一的待办），自己的浏览器正好用它，出网全在我们的规则里。
5. 登录状态留在我们自己的加密存储里，删账号就销毁。

分步：

1. **实测（约 1.5 天）**：东京 ACS 上跑 Chromium，量内存和 CPU、看能不能开 Chromium 自己的沙箱（多半要 `--no-sandbox`）、
   `/dev/shm`、镜像变大后的冷启动（Chromium 连依赖约 0.65–0.8 GB），定规格。
2. **A 阶段**：出口代理（挡内网和元数据地址，按实例记账、限速）→ 浏览器版镜像（Chromium、中文字体、固定版本的 Playwright MCP）
   → agent-shim 起 Chromium（只听 127.0.0.1，经代理出网，配置放工作区里）→ 五个 agent 都接同一个 Playwright MCP（OpenClaw、
   Pi 要写进它们自己的配置文件，顺带让它们第一次拿到平台工具）→ 每个实例一个“让它用浏览器”开关，默认关。
3. **B 阶段**：App 里“看浏览器”和“接管”（CDP 截帧经网关 WebSocket 推到手机，点按、输入法文字传回去）；agent 遇到登录、验证码、
   支付时请用户接手，推送叫人，30 分钟没人管就告诉 agent。
4. **以后按需**：国内网站因为日本 IP 失败的任务多了（比如超过两成）、没 Mac 的用户要登国内网站、收入够付套餐费时，再接 AgentBay
   国内版当“大陆浏览器”（先花一个月 Pro 实测延迟、手机上的实时画面、登录保持、真实规格，并拿到能给用户看画面的书面确认）。
   “以我的身份”登淘宝、银行、微信，优先走用户自己的电脑（14.4，现在只支持 Mac）。

## 6. 风险和要定的事

- **出口代理是安全关键件**：DNS、IP 检查有漏洞就能打到我们内网（RDS、sandbox-manager）。要明确拒绝 VPC 网段和
  100.100.100.200，要测试。
- **网页里的提示注入加上保存的登录**：agent 可能被网页诱导，以用户身份发帖、下单、发消息。按工具种类的审批不是安全边界，预授权
  浏览器工具等于去掉每一步的确认。
- **合规（要问律师）**：东京的浏览器把被屏蔽的外网画面实时推给大陆手机，可能被看成跨境访问服务；cookie、浏览记录出境涉及个人信息
  保护法第 38、39 条（我们放东京的工作区数据本来也有这个问题）。在大陆部署要 ICP 备案。自动化访问要符合《网络数据安全管理条例》
  第 18 条，不宣传绕过验证码。
- **共用的东京 IP**：一个用户乱来，整个 IP 被网站拉黑，大家都受影响；Google 可能频繁出验证码。
- **许可证**：可以用 Playwright、Playwright MCP、chrome-devtools-mcp、agent-browser（Apache-2.0）、browser-use（MIT）、
  noVNC（MPL-2.0）；不用 Browserless 开源版（SSPL，要公开我们整个服务）和 AGPL 的 nodriver、Lightpanda。chrome-devtools-mcp
  默认上报使用统计、性能工具会把网址发给 Google，要关掉。
- **Hermes**：镜像里一有 `/usr/bin/chromium`，Hermes 0.19 就会自己挂出 12 个浏览器工具，调用时去 `npx agent-browser` 下载；
  要么关掉它的浏览器工具，要么把它指到同一个 Chromium（`BROWSER_CDP_URL`）并装好 agent-browser。
- **Chrome 136 起**用户默认配置不再开放远程调试：14.4 想控制用户日常用的 Chrome，要换成专门的自动化配置（用户登录一次）或插件。
- 要用户定：浏览默认开还是关（建议关）；东京 IP 在国内网站上的提示怎么说；预算上限（每人每天多少分钟）。

## 7. 来源

- AgentBay 是什么、四类环境：https://help.aliyun.com/zh/agentbay/product-overview/what-is-eds-agentbay
- 浏览器用法、CDP 要付费套餐：https://help.aliyun.com/zh/agentbay/agentbay-browseruse
- 价格（国内，2026-06-24）：https://help.aliyun.com/zh/agentbay/product-overview/agentbay-billing-instructions
- 价格（国际）：https://www.alibabacloud.com/help/en/agentbay/product-overview/agentbay-billing-instructions
- 新用户试用（积分只抵计算费）：https://help.aliyun.com/zh/agentbay/product-overview/new-user-trial-instructions
- 地域（SDK：杭州、新加坡、弗吉尼亚）：https://github.com/agentbay-ai/wuying-agentbay-sdk/blob/main/docs/guides/common-features/configuration/sdk-configuration.md
- 实时画面链接有效期和次数限制：https://help.aliyun.com/zh/agentbay/mcp-access-guide
- Session Link 白名单：https://github.com/agentbay-ai/wuying-agentbay-sdk/issues/407
- 接手（call for user）、验证码（只支持滑块）：https://github.com/agentbay-ai/wuying-agentbay-sdk/tree/main/docs/guides/browser-use/core-features
- Web SDK 条款：https://help.aliyun.com/zh/agentbay/web-sdk-of-agentbay
- 安全白皮书：https://help.aliyun.com/zh/agentbay/agentbay-security-white-paper
- ACS Agent Sandbox 价格：https://help.aliyun.com/zh/cs/user-guide/agent-sandbox/
- ACS 计费：https://help.aliyun.com/zh/cs/product-overview/product-billing-rules
- 函数计算浏览器沙箱（AgentRun / FC Cloud Sandbox，邀请制预览）：https://help.aliyun.com/zh/functioncompute/browser-template ，
  https://help.aliyun.com/zh/functioncompute/pay-as-you-go-of-fc-agent-sandbox
- EIP 按流量价格：https://help.aliyun.com/zh/eip/pay-as-you-go/
- Playwright MCP：https://github.com/microsoft/playwright-mcp ；chrome-devtools-mcp：https://github.com/ChromeDevTools/chrome-devtools-mcp
- Chromium 内存实测（空闲约 700 MB）：https://datawookie.dev/blog/2025-06-06-playwright-browser-footprint/
- Chrome 136 远程调试变化：https://developer.chrome.com/blog/remote-debugging-port
- IP 属地规定：https://www.cac.gov.cn/2022-06/26/c_1657868775042841.htm
- 工信部 2017 跨境专线通知：https://www.cac.gov.cn/2017-01/26/c_1120381529.htm
- 网络数据安全管理条例：https://www.cac.gov.cn/2024-09/30/c_1729384452307680.htm
- 国外同类服务价格参考：https://www.browserbase.com/pricing ，https://steel.dev/pricing

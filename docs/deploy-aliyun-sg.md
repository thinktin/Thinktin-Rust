# 阿里云新加坡部署计划

> 2026-10-27 写，**还没部署**。由 Claude 在云端会话里执行，用户负责开账号、付钱和只有本人能点的授权。
> **2026-10-28 改地域**：用户换成**国内站 aliyun.com 账号**（国际站要证件实名，太慢），地域选**日本东京 `ap-northeast-1`**。东京已查过（只读）：ACS 的 1.36.2、1.35.7、1.34.10 都有 `ack-agent-sandbox-controller` v0.6.6 和 `ack-sandbox-manager` v0.6.13；4 核 8G 的 `ecs.u1-c1m2.xlarge` 在可用区 a、b、c，RDS PostgreSQL 16 在 a、b，所以都放**可用区 a**。下文写“新加坡”的地方按东京理解，脚本跑时加 `--region ap-northeast-1`；国际站账号上建的新加坡网络不收费，以后删掉。
> 通用的准备清单见[部署环境准备清单](deploy-checklist.md)；这份是它在“阿里云新加坡、起步规模”下的具体做法，两者不一致时以这份为准。

## 0. 已经定下来的

| 事项 | 决定 | 来由 |
|---|---|---|
| 部署地点 | **整套放阿里云新加坡**（`ap-southeast-1`） | 要开箱直连 Claude、GPT、Grok、Gemini 等。阿里云国内连不上它们，OpenAI、Anthropic 也不支持中国大陆、香港。新加坡比东京多了现成的阿里云沙箱，成本差不多 |
| 模型 | **所有厂商直连**：海外品牌方，加上国内厂商的国际站接口（DeepSeek、通义国际站、Kimi、智谱 Z.ai、MiniMax 等） | 用户 2026-10-27 |
| 分发 | 先不进国内应用商店（要备案、要服务器在国内）：iOS 走海外区 App Store，安卓走官网 APK 和 Google Play | 放海外的代价，用户已知 |
| agent 沙箱 | **ACS 的 Agent Sandbox（容器版）**；新加坡开不了或实测过不去就用**智能体沙箱极速版**；**不部署 Cube**，代码留着以后自建用 | 调研见第 6 节 |
| 主密钥 | **本地主密钥**（`kms.provider = "local"`），不买阿里云 KMS：海外实例每月约 ¥3,500。以后切换时旧数据照样解得开 | 成本 |
| 谁来部署 | Claude 用 RAM 子账号的 AccessKey 调阿里云接口；**花钱的资源先列清单、用户同意后再建** | 用户 2026-10-27 |

## 1. 部署后的样子

```
用户的 App / Mac ──https──▶ 服务机（ECS，公网 IP）
                            k3s 单机 Kubernetes：
                              thinktin-api      接口
                              thinktin-worker   后台（执行器、推送）
                              thinktin-llm-gw   模型网关 ──https──▶ Claude / GPT / Grok / DeepSeek …
                              thinktin-relay    设备中继（wss）
                              Caddy             HTTPS 证书（Let's Encrypt）、反向代理
                 │ VPC 内网
                 ├──▶ RDS PostgreSQL 16（只开内网）
                 ├──▶ OSS 桶（产出物，走内网地址）
                 └──▶ ACS 集群：Agent Sandbox（每个 agent 实例一个沙箱）
                          沙箱只能访问服务机上的模型网关，彼此不通、不能上公网
```

- **服务为什么放一台 ECS，不放 ACS**：服务要出公网（模型厂商、推送、短信）。放 ACS 要配 NAT 网关和负载均衡，每月多几百块；ECS 自带公网 IP，进出都有了。部署清单里写的 ACK 和多副本，用户多了再上。
- **沙箱为什么在 ACS**：沙箱只连内网里的模型网关、不上公网，不需要 NAT。ACS 不收集群管理费，沙箱休眠时不收 CPU 和内存费用。
- **我怎么操作服务机**：用 ECS 的**云助手**（`RunCommand` 接口）在机器上执行命令，不开 SSH 端口。

## 2. 资源清单和每月费用（估算，下单前在价格计算器核实）

| 资源 | 规格 | 每月约 | 说明 |
|---|---|---|---|
| ECS 服务机 | 4 核 8G（通用算力型 u1 或 g8i），40G ESSD 系统盘，按流量计费的公网 IPv4 | ¥300–500 | 包年包月更便宜，海外机型常有首年活动价 |
| 公网流量 | 按流量 | ¥20–50 | 新加坡约 ¥0.53/GB（第三方整理，待核实），只算出方向 |
| RDS PostgreSQL 16 | 基础系列 2 核 4G，50–100G，自动备份 | ¥300–450 | 海外价格没查到官方数，按国内价加五成估；只开内网 |
| OSS | 一个私有桶，标准存储，按量 | < ¥10 | 产出物 |
| ACS 集群 | 不收管理费；Agent Sandbox 的管理组件：测试配置（`run.sh acs --addons`）约 1 核 2G，组件默认配置 4 核 8G 起 | 测试 ¥130；默认 ¥500 以上 | 海外通用算力每核每小时 ¥0.089、每 GB 每小时 ¥0.044；正式要几个副本、多大，压测后定 |
| Agent 沙箱 | 每个 agent 1 核 2G，用时计费 | 每个活跃用户约 ¥16–18 | 海外每核每小时 ¥0.123、每 GB 每小时 ¥0.062；休眠只收存储 |
| 容器镜像服务 ACR | 个人版 | ¥0 | 放 agent 模板镜像（沙箱要求镜像在同一地域）。服务镜像继续用 GitHub 的 ghcr.io |
| 域名 | 一个 | ¥60–100/年 | 海外部署不用 ICP 备案 |
| HTTPS 证书、监控 | Let's Encrypt、云监控基础版 | ¥0 | |
| 短信 | 按条 | 约 ¥0.045/条 | 见第 7 节，要先确认能发 |
| **合计** | | **约 ¥750–1,150/月 + 每个活跃用户约 ¥17** | 模型 token 由用户自带 key 付，不算在内 |

## 3. 用户要做的（只能本人来）

1. **注册阿里云并实名认证**，最好用公司主体。国内站账号也能买新加坡的资源。
2. **充值，设预算提醒**（费用中心 → 预算管理，比如每月超过 ¥1,000 提醒）。
3. **开通产品**（第一次开通要同意协议、授权服务角色）：ECS、RDS、OSS、容器计算服务 ACS、容器镜像服务 ACR。开 ACS 时确认新加坡能开 **Agent Sandbox**，开不了就开通**智能体沙箱极速版**。
4. **建 RAM 子账号给 Claude**：访问控制 RAM → 用户 → 新建 `thinktin-deploy`，只勾“OpenAPI 调用访问”。授权：
   `AliyunECSFullAccess`、`AliyunVPCFullAccess`、`AliyunRDSFullAccess`、`AliyunOSSFullAccess`、`AliyunCSFullAccess`、
   `AliyunContainerRegistryFullAccess`、`AliyunBSSReadOnlyAccess`（只读账单），域名在阿里云时加 `AliyunDNSFullAccess`；
   用极速版时再加函数计算的权限。然后创建 AccessKey。
5. **把 Key 放进云端环境，不要发到聊天里**：网页版 claude.ai/code，会话标题后的 ▾ → Edit cloud environment（或新建会话页输入框下面的
   环境选择器 → 环境那一行的齿轮）→ **环境变量**（Environment variables）里填两行 `ALIBABA_CLOUD_ACCESS_KEY_ID=…`、
   `ALIBABA_CLOUD_ACCESS_KEY_SECRET=…`，保存。**不要**填进“设置脚本”（那里设的变量脚本跑完就没了），也**不要**用 Network secrets
   （它只会把 Key 原样塞进请求头，阿里云的 Key 是拿来给请求签名的，用不了）。**存好后开新会话**，仓库选 `thinktin/Thinktin-Rust`，
   环境选存了 Key 的那个；会话只在虚拟机启动时读环境变量，老会话读不到。
6. **域名**：买一个（或用已有的），要两个子域名，比如 `api.<域名>`、`relay.<域名>`。域名在阿里云就把 DNS 权限给子账号；不在阿里云的话，Claude 会给出要加的 DNS 记录，由你去加。
7. **集群里的权限**（用 kubectl 时要）：ACS 控制台 → 授权管理 → RAM 用户 `thinktin-deploy` → 选集群、所有命名空间、管理员。
   RAM 策略只管 OpenAPI，集群里面的权限要单独给。
8. **GitHub 仓库的密钥**（第 4 阶段要）：ACR 的登录用户名和密码加到仓库的 Actions secrets，用来把 agent 模板镜像推进 ACR。会话里的 GitHub 工具不能设仓库密钥。

## 4. Claude 的部署步骤

每个阶段开始前，Claude 列出要建的资源和每月费用，**用户同意后才建**。部署脚本放在 `deploy/aliyun/`（阿里云官方 Python SDK，按名字查找已有资源，重跑不会重复建），密钥不进仓库、不进聊天。

| 阶段 | 做什么 | 怎么验证 |
|---|---|---|
| 1. 网络和存储 | VPC、两个交换机（服务、沙箱分开）、安全组（服务机只开 80/443；数据库只许服务机连）；OSS 桶；ACR 命名空间 | 用接口查回来，和清单一致 |
| 2. 数据库和服务机 | RDS PostgreSQL 16（只开内网、自动备份）；ECS 4 核 8G，开云助手；在机器上装 k3s 和 Caddy | 云助手执行 `kubectl get nodes`；服务机能连上数据库 |
| 3. 平台服务 | 新加一个部署配置 `deploy/k8s/overlays/sg`（单副本、本地主密钥、OSS 新加坡内网地址、沙箱指向 ACS）；建数据库角色（[准备清单](deploy-checklist.md)第 3 节）；在机器上执行 `gen-secrets`，密钥直接写进 Kubernetes Secret，不打印；跑迁移；起四个服务；配域名和证书 | `https://api.<域名>/healthz`、`/version` 正常；中继的 wss 能连上；`cargo test -p server deployment_configs_are_valid` 包含新配置 |
| 4. 沙箱 | 建 ACS 集群（沙箱交换机）；装 Agent Sandbox 的组件；网络策略（沙箱只能连模型网关、彼此不通、封元数据地址 `100.100.100.200`）；5 个 agent 的模板镜像推进 ACR、注册模板；沙箱后端对接 ACS（第 5 节）；按第 6 节逐条实测 | 每个 agent 在真沙箱里跑通冒烟任务；第 6 节全部打勾 |
| 5. 客户端和上线前 | App 的接口地址指到 `api.<域名>`，出测试版（TestFlight、APK）；推送证书到位后接上；数据库备份恢复演练；费用和告警 | 真机走一遍：登录、领养、配 key、下任务、审批、推送 |

## 5. 要改的代码（部署前在仓库里做）

| 改动 | 估计 |
|---|---|
| 部署配置 `deploy/k8s/overlays/sg`（k3s 单机、单副本、本地主密钥），加进配置校验测试 | 0.5 天 |
| 部署脚本 `deploy/aliyun/`：建网络、存储、数据库、服务机、ACS，云助手执行命令 | 2 天 |
| 沙箱后端对接 ACS 的 E2B 接口：数据面地址和鉴权按 ACS 的方式；建沙箱时设超时到期“休眠”、保留时长；拿到每个沙箱自己的内网地址 | **10-28 写完**（`AcsProvider`，[ACS 后端](sandbox-acs.md)），没连过真集群 |
| 模型网关的来源地址校验：Cube 是整个节点一个出口地址；ACS 里每个沙箱有自己的内网地址，改成绑定到这个沙箱的地址（更严） | **10-28 写完**：令牌绑 Pod IP，拿不到 IP 不建沙箱；网关用主机网络 |
| 工作区保留：如果 ACS 的卷不好用，改成销毁沙箱前把工作区打包存进 OSS、重建时放回（架构方案里原本的“冷存档”） | **10-28 写完**（`[sandbox.workspace] mode = "object"`，加密存 OSS，迁移 0023） |
| 东京的部署配置（第 8.9 节的单机方案） | **10-28 写完**：`deploy/k8s/overlays/tokyo` |

## 6. 沙箱实测清单（第 4 阶段，任何一条过不去都要先解决）

| 要确认的 | 为什么 |
|---|---|
| 新加坡的 ACS 能开 Agent Sandbox | 开不了就换极速版 |
| 沙箱能连续运行多久 | 任务等审批时沙箱一直开着，可能几个小时 |
| 休眠能保留多久（我们要 7 天） | ACS 文档说默认永久，可以设 |
| 休眠的沙箱占不占并发名额 | 占的话，用户一多名额就满 |
| 长时间没输出时连接会不会被断 | 等审批期间 agent 没输出 |
| 沙箱访问不了元数据地址 `100.100.100.200` | 能访问就可能拿到云上的临时凭证 |
| 沙箱之间不通，出网只到模型网关 | 多租户隔离的根本 |
| 工作区：卷（按用户分子目录、权限收窄）能不能用 | 不能用就做第 5 节的打包存 OSS |
| 冷启动和唤醒要多久（5 个 agent 各测一次） | 影响第一次对话的等待 |
| 账单：运行、休眠各按什么收 | 核对第 2 节的估算 |

## 7. 上线前还要确认的

- **短信登录**：现在只有手机验证码登录。阿里云短信的签名和模板要审核，申请时可能要备案或 App 资料；发不了的话要加邮箱、Apple、Google 登录。**这是上线的前置条件**，建议账号一开就申请。
- **备案**：服务器在新加坡，不用办 ICP 备案（只有中国内地的服务器要），国内站账号买新加坡也一样；账号本身要实名，域名要做域名实名认证，都不是备案。**但 App 上国内商店（苹果中国区、国内安卓商店）要 App 备案号**，苹果后台会校验。App 备案要国内主体，经境内的接入服务商办，后端只在新加坡一般办不了。不上国内商店（只上海外区、直接发 APK）就不涉及；要上的话，上线前定方案（比如加一个国内的入口再备案），和合规一起请法务看。
- **合规**：中国用户的个人信息存在新加坡，涉及个人信息出境；面向国内用户提供未备案的境外模型。建议上线前请法务看一次（16.4、16.6）。
- **隐私政策**：写明服务器在新加坡、会把内容发给用户自己选的模型厂商。
- **Apple 开发者账号**：推送（APNs）和上架都要。
- **安卓推送**：极光和 FCM 还没定（进度文件“待决问题”）。

## 8. 密钥和权限

- AccessKey 只放在云端环境的密钥设置里；部署用完可以在 RAM 里停用，要用时再启用。
- 平台的密钥（访问令牌、沙箱令牌、主密钥、数据库密码）在服务机上生成、直接写进 Kubernetes Secret，不出现在聊天和仓库里。要备份时由用户在控制台或云助手里导出，存进密码管理器。
- 上次在聊天里贴过的 Codemagic 密钥，用户去 Codemagic 作废换新。

## 8.5 第一次检查结果（2026-10-27，用户的阿里云账号）

`deploy/aliyun/run.sh check` 在新会话里用真 Key 跑过（只读）：

- **通过**：Key 是 RAM 子账号 `thinktin-deploy`；新加坡有 4 核 8G 的 `ecs.u1-c1m2.xlarge`（可用区 a、b、c）和 `ecs.c9i.xlarge`（a、d）；
  还没有 VPC；RDS 的 PostgreSQL 16 在 a、b、c 可买；ACS 接口能调、还没有集群。
- **不通过**：OSS 报 `UserDisable`，OSS 还没开通（或账号欠费）。
- **余额 0.00 USD**：是**国际站**账号（按美元计价），下单前要绑定付款方式或充值。第 2 节的人民币估算照汇率换算即可。

## 8.6 进度

| 阶段 | 状态 | 资源 |
|---|---|---|
| **Rust 的 `AcsProvider` 连真集群（东京）** | **2026-11-10 16:40 UTC，一次全过**。`crates/sandbox/examples/acs_probe.rs` 编成 release（这里和服务机都是 glibc 2.39），`run.sh ecs --push` 传上去（xz 后 2 MB、153 块、并行 4 路约 2 分钟），服务机上 `bash deploy/aliyun/probe-acs.sh`，sandbox-manager 直接连它的 Pod IP `172.29.47.90:7788`（同一个 VPC 路由得到，**不用内网负载均衡**；Pod 重建地址会变，正式用要么加内网 CLB 约 ¥43/月，要么服务机上按 Endpoints 更新反代的上游，还没定）。结果：建沙箱 0.1 秒（预热池），返回的地址就是 Pod IP 172.16.24.93（`sandbox-ip` 在 v0.6.14 有）；`get` 一致；读写文件、读超上限会拒绝；命令的 stdin、关 stdin、stderr、退出码 7 都对；环境变量、工作目录 `<root>/workspace`、用户 `user`、`HOME=<root>/home` 都对，镜像里有 GNU tar 1.34；90 秒没输出没断；**沙箱连服务机 8790 通，服务机看到的来源地址是 Pod IP（没有 SNAT）**，令牌绑 Pod IP 成立；暂停 2.9 秒（状态 Paused）、恢复 0.4 秒、地址没变、文件还在、还能跑命令；16 MB 文件上传 0.1 秒、下载 0.2 秒；**空闲 330 秒还在**（`timeout: 300` + never-timeout 起作用）；删除后查不到。预热池删了，`default` 空了。没测的：暂停期间的计费和保留时长、工作区归档（大工作区存放、OSS 签名区域）、5 种 agent 自己的镜像 | — |
| **沙箱隔离 + 第二次实测（东京）** | **2026-11-10 16:30 UTC 左右做完**（用户同意建，不收费）。按阿里云文档“Agent Sandbox 网络规划与扩容”：`run.sh network --apply` 建了沙箱自己的交换机 `thinktin-sbx-c` vsw-6weapu5acc0y0rpoe0z1m（172.16.16.0/20，可用区 c；**集群是双栈的，交换机要开 IPv6**，不然 Pod 报 `Ipv6AddressNotSupportVsw`，开了第 16 个 /64）和企业级安全组 `thinktin-sbx` sg-6we220m9hfjlzleztul4（组内隔离；入方向只许集群三个交换机网段连 49983、49999、ICMP；出方向拒绝 100.100.100.200，许 172.16.0.0/24 的 8790–8791、集群网段的 6443 / 53 / 49983 / 9082，拒绝别的私网，许 100.64.0.0/10（镜像仓库等阿里云内部服务），公网拒绝），ID 在 `target/aliyun-acs/network.json`，SandboxSet 的模板带 `network.alibabacloud.com/vswitch-ids`、`security-group-ids` 两个注解。<br>**第二次实测**（沙箱 IP 172.16.24.x）：沙箱之间 **不通了**（B → A:8000、两边互连 envd 49983 都不通）；镜像拉得下来（45 秒）、建、读写文件、出不了公网、300 秒不断、暂停 3.5 秒 / 恢复 0.5 秒、文件还在，都照旧；冷启动 73 秒。<br>**元数据地址**：安全组的拒绝规则挡不住 TCP 80 的握手（还是“通”），但进沙箱里看过（`sandbox --acs --apply --exec "$(cat deploy/aliyun/probe-metadata.sh)"`）：读目录、读角色、读实例信息、PUT 取令牌 **全部 403**，443 不通，什么都拿不到。算残余风险（连得上、不给东西）；实测脚本改成看它回什么（200 才算漏）。要彻底不通的话以后在我们自己的沙箱镜像里加规则，或者用组件的 TrafficPolicy。<br>**副作用**：安全组不放 10250，`kubectl exec / logs` 进不了沙箱（要看沙箱里的东西用上面的 `--exec`）。<br>**收尾**：预热池删了，`default` 命名空间清空 | — |
| **沙箱实测（东京，第一次）** | **2026-11-10 15:20 UTC 跑完**（用户用主账号开通了 Agent Sandbox 容器版服务；旧的预热池不会自己重试，删了重建，Pod 81 秒 Running）。在服务机上 `run.sh sandbox --acs --apply`，组件 controller v0.6.7-release.2、manager v0.6.14-release.1、E2B SDK 2.50.0、镜像 code-interpreter:v1.6：<br>**通过**：从预热池拿 0.1 秒；池子空了冷启动 66.6 秒；规格 1 核 1024 MB、30G 盘、envd 0.2.10、内核 5.10.134 lifsea8；读写文件；出网到 api.anthropic.com / api.openai.com / api.x.ai / generativelanguage.googleapis.com 都不通（没有 NAT）；300 秒没输出连接没断；暂停 3.5 秒、状态 paused、恢复 0.4 秒、文件还在；删除成功；admin Key 找得到 `default` 命名空间里的 SandboxSet。<br>**不通过（上线前必须解决）**：① 元数据地址 `100.100.100.200:80` **通**；② 沙箱之间**互通**：B → A:8000 通，两边互连 envd 的 49983 也通（A 172.29.47.92、B 172.29.47.94，同一个 Pod 交换机）。默认没有任何隔离，要加规则再测：集群里有 `networkpolicies`（ACS 上要装 Poseidon 组件才生效，没装）和沙箱组件自己的 `trafficpolicies` / `globaltrafficpolicies`、`securityprofiles`（controller 的 `trafficPolicy.enabled` 现在是 false）。<br>**收尾**：预热池删了、测试的 Pod 清干净了（`default` 命名空间空了），现在没有沙箱在计费。sandbox.py 没测的：暂停期间的计费、暂停能留多久、休眠占不占并发、5 种 agent 的镜像。日志在服务机 `/opt/thinktin/sandbox-test.log` | — |
| 预热池（东京） | **2026-11-10 15:00 UTC**：用户把子账号改成集群管理员以后 `run.sh acs --pool --offline --apply` 建了 SandboxSet `code-interpreter`，沙箱 Pod 一直 Pending：`AccountForbidden.AuthorizationRequired: Your account commodity is not activated`。沙箱 Pod 的算力类型是 `alibabacloud.com/compute-class: agent-sandbox`（组件自己的容器是 `general-purpose`，能跑），账号还没开通 **Agent Sandbox 容器版服务**。控制台集群列表顶上的“开通状态”那一行只有 GPU 按量、GPU 容量预留、CPU 按量三项（用户拍了照，CPU 已开通），不在那里；官方文档（help.aliyun.com/zh/cs/user-guide/create-an-agent-sandbox 的“准备工作”）给的开通链接是 `https://common-buy.aliyun.com/?commodityCode=acs_sandbox_public_cn`，要主账号本人点、同意协议。文档还要求已有集群的 acs-virtual-node ≥ v2.17.0、调度器够新：查过了，集群是 ack-virtual-node v2.19.1、ack-scheduler v1.36.0-apsara.6.12.6，都够。预热池留着没删（没起来的 Pod 不收费），用户开通后看它自己起不起得来，不行就删了重建 | — |
| 服务机上跑 kubectl（东京） | **2026-11-10**：`acs.py` 加了 `--fetch-kubeconfig`（云端会话里取短时的内网 kubeconfig）和 `--offline`（服务机上不调 OpenAPI）；脚本和 `target/aliyun-acs`（kubeconfig、sandbox.json）用 `run.sh ecs --push` 传到服务机 `/opt/thinktin`，装了 python3-venv，kubectl v1.36.5 下载并核对过，连得上 API Server。**卡在集群里的权限**：子账号 `claude-deploy`（uid 204116993123321749）在集群里没有 RBAC，`kubectl get pods` 是 Forbidden。用户同意后试了用接口加（CS 的 UpdateUserPermissions）：**阿里云拒绝**（`ForbiddenGrantPermissions`，子账号不能给自己加集群权限，RAM 的 AdministratorAccess 也不行），只能用户用主账号在 ACS 控制台 → 授权管理 → RAM 用户 `claude-deploy` → 集群 `Thinktin-Rust`、所有命名空间、管理员。加好以后在服务机上 `run.sh acs --pool --offline` 接着做（kubeconfig 4 小时失效，过期了在云端会话里重取、重传）。**14:57 UTC 用户说加好了，但加的不是管理员**：能列 Pod、能 port-forward、能读 Secret，`sandboxsets.agents.kruise.io` 还是 Forbidden，也不能建命名空间、动节点、看 RBAC（像预置的“开发人员”或“运维人员”，它们不含 `agents.kruise.io`）。请用户改成“管理员”。组件的容器在跑：`sandbox-system` 里 sandbox-manager 2/2、sandbox-gateway 1/1。用户已同意沙箱实测的花费（几块钱） | — |
| 组件、网络、服务机（东京） | **2026-11-10 做完**（用户点了授权、同意网络、服务机按量买）：① 服务角色 `AliyunCSManagedAgentSandboxRole` 用户点完几分钟后才查得到（RAM 有延迟）。② 沙箱组件装好、都是 active：`ack-agent-sandbox-controller` v0.6.7-release.2（默认配置）、`ack-sandbox-manager` v0.6.14-release.1（测试配置：两边各 1 个副本 500m / 1Gi，不收日志，估算每月约 ¥129；新版的配置校验不认 `0.5`，要写 `500m`）；adminApiKey 在 `target/aliyun-acs/sandbox.json`（容器回收丢了的话重跑 `run.sh acs --addons` 会从组件配置里读回来）。③ 网络（不收费）：交换机 `thinktin-svc-a` vsw-6weq325864hjuhrbtv0c8（172.16.0.0/24，可用区 a）、安全组 `thinktin-svc` sg-6weaw27reqprxrk33n2i（80、443 对公网，8790、8791 只对 VPC）。④ 服务机 `thinktin-svc` i-6weeftl117xawndcgpaq：`ecs.e-c1m2.large`（2 核 4G），Ubuntu 24.04，40G 系统盘 + 20G 数据盘（还没格式化），内网 172.16.0.168，公网 8.216.52.81，按量每小时 ¥0.2984；不开 22，只用云助手（`run.sh ecs --run / --run-file / --push`，新脚本 `deploy/aliyun/ecs.py`）；试过能跑命令、连得上集群 API Server 的内网地址（healthz 200）、能上外网。**现在每天约 ¥13**：服务机 ¥7.2、组件约 ¥4.3、集群的 CLB ¥1.4。**下一步**：kubectl 那几步（预热池、沙箱实测）在服务机上跑：`acs.py` 的 `pool` 和 `sandbox.py --acs` 现在自己用 AccessKey 取 kubeconfig，服务机上没有 Key（也不往上放）；打算在云端会话里取一份短时的内网 kubeconfig，和 `sandbox.json` 一起用 `--push` 传上去，脚本加一个不调 OpenAPI 的离线模式。预热池和实测要建沙箱（收费，几块钱），先问用户 | — |
| 开始部署（东京） | **2026-11-10**：用户充了 ¥300（余额 ¥289.75），说开始。① 装沙箱组件 `run.sh acs --addons --apply`（测试配置约 1.2 核 2G、每月约 ¥146，用户同意了）：**卡在授权**，要主账号在 RAM 控制台同意服务角色 `AliyunCSManagedAgentSandboxRole`（脚本现在会把完整的授权链接打出来），用户点了以后重跑。② 服务机的网络 `run.sh network`（集群的 VPC 里加交换机 `thinktin-svc-a` 172.16.0.0/24 和安全组 `thinktin-svc`，不收费）：只看了计划，`--apply` 被会话的自动审查拦了，等用户明确同意。③ 服务机还没买，也还没有建机器、用云助手跑命令的脚本；查到的价（40G 系统盘 + 20G 数据盘，按流量公网）：`ecs.e-c1m2.large` 按量 ¥0.2984/时、包月 ¥139.27，可用区 a 有货 | — |
| 检查（国内站，东京，第三次） | **2026-11-10**（只读：`run.sh check`、`run.sh acs`、按产品查账单）：全部通过，但**余额 -10.25 元（欠费）**。唯一在收钱的是集群 API Server 的传统型负载均衡 CLB（按量）：10 月 ¥11.10（加已释放的 EIP ¥0.69），11 月到今天 ¥13.46，约 ¥1.4/天、每月约 ¥43（第 8.9 节的估算里没算这一项）。用户 10-28 充的 ¥15 大约 11 月 3 日用完。集群 `Thinktin-Rust` 还是 running，沙箱组件都没装，可装的版本变成 controller v0.6.7-release.2、manager v0.6.14-release.1；OSS 0 个桶。**下一步等用户充值**（按量付费的 ECS 下单要余额不少于 ¥100），然后按交接文档第 4 节第 3 步起做，每一步先列费用 | — |
| 代码 | **2026-10-28 写完**：ACS 沙箱后端、令牌绑沙箱 IP、计时可配、工作区存 OSS、东京部署配置（第 5 节）。只对着模拟服务测过；实测清单见 [ACS 后端](sandbox-acs.md) 第 8 节，部署时要定的见 [交接文档](handoff.md) 第 4 节第 9 条 | — |
| API Server 公网 | **2026-10-28 解绑**（用户同意，ModifyCluster api_server_eip=false）：只剩内网 172.29.47.77:6443。EIP eip-6we3j5f74oq6xzbeacf39（47.74.56.251，按流量）**10-29 用户在控制台释放了**（只读查过已经没了） | — |
| 检查（国内站，东京，第二次） | **2026-10-28**：全部通过（用户给 `claude-deploy` 加了 `AdministratorAccess`）；余额 0.00 元（国内站预付，付费资源下单前要充值）。集群 `Thinktin-Rust`（ce2dbb6f0799b4a65bbb31821d8a4623b，ACS 1.36.2，VPC vpc-6weeobj130h915q49t32h，API Server 公网 47.74.56.251:6443、内网 172.29.47.77:6443）。沙箱组件都没装：controller v0.6.6-release.5、manager v0.6.13-release.1；manager 默认约 36 核 48G、每月约 ¥3,900，测试配置约 1.2 核 2G、每月约 ¥146（`run.sh acs --addons` 打印） | — |
| 检查（国内站，东京） | **2026-10-28**：Key 是 RAM 子账号 `claude-deploy`。通过：东京 4 核 8G 的 `ecs.u1-c1m2.xlarge`（a、b、c）、RDS PostgreSQL 16（a、b）、ACS 接口能调。不通过：VPC（缺 `AliyunVPCFullAccess`）、OSS（缺 `AliyunOSSFullAccess`）、余额（缺 `AliyunBSSReadOnlyAccess`）。**东京还没有集群**（香港、杭州、上海、北京、深圳、硅谷也没有） | — |
| 容器版脚本 | **2026-10-28 写好，等 Key 和集群**：`run.sh acs`（找集群、看 / 装沙箱组件，OpenAPI，云端会话能跑）、`run.sh acs --pool`、`run.sh sandbox --acs`（要 kubectl，只能在集群 VPC 里的机器上跑：云端会话的代理只放行 443，API Server 在 6443、要客户端证书、port-forward 要 WebSocket）。只在本机用假服务验过私有协议的地址，没连过真集群。下一步见 [交接文档](handoff.md) 第 4 节 | — |
| 检查 | 2026-10-27 全部通过（OSS 已开通；余额 0 USD，付费资源下单前要绑卡或充值） | — |
| 1. 网络 | **2026-10-27 已建**（`deploy/aliyun/run.sh network --apply`，不收费） | VPC `thinktin-sg` vpc-t4nnamzms0ug1sro2xnsh（10.10.0.0/16）；交换机 `thinktin-svc-a` vsw-t4nkrp5vkmskd7u8l3iym（10.10.1.0/24）、`thinktin-sbx-a` vsw-t4noo1zilrxuce545tf2w（10.10.16.0/20），都在 ap-southeast-1a；安全组 `thinktin-svc` sg-t4ng934e0iz30f7mdie9（入方向 80、443） |
| 沙箱测试 | **直接测容器版**（2026-10-27 用户定：正式就用容器版，不绕道极速版）。新加坡 ACS 的组件列表里有 `ack-agent-sandbox-controller` 和 `ack-sandbox-manager`（2026-10-27 用 ListAddons 查到，ACS 1.37.1）。测试不建 ALB、不要域名和证书：集群 API Server 开公网（绑一个按流量的 EIP），从云端会话 `kubectl port-forward` 到 sandbox-manager，用私有协议走 HTTP；E2B 的 Key 是装 `ack-sandbox-manager` 时自己设的 `adminApiKey`，不用去控制台建。预热池设 1 个。测完删沙箱，集群留不留再定。`deploy/aliyun/run.sh sandbox` 改成能连 port-forward 的地址后复用 | **卡在实名认证**：国际站账号开通产品前要实名，用户在选国际站认证还是换国内站 aliyun.com 账号（第 1 阶段网络可在新账号重建，不收费）。认证后用户在控制台开通 ACS（第一次要本人同意协议、授权服务角色），其余由 Claude 用 AccessKey 建 |

### 8.7 极速版的 E2B 接口（2026-10-27 查文档、用假 Key 试过；现在不用极速版，留作备选）

- 两个地址都在，没 Key 都返回 401：`api.ap-southeast-1.sandbox.aliyuncs.com`（智能体沙箱）和 `api.ap-southeast-1.e2b.fc.aliyuncs.com`（函数计算云沙箱）。
  Key 是哪边控制台建的就用哪边，`run.sh sandbox` 会自动找；也可以用环境变量 `ALIYUN_SANDBOX_DOMAIN` 指定。
- SDK：极速版文档测的是 `e2b==2.31.0`；`requirements.txt` 10-28 起钉容器版要的 `2.50.0`，极速版只是备选，没再测。
  极速版的 Key 不是 `e2b_` 开头，要关掉 SDK 的 Key 格式校验。
- [兼容接口列表](https://help.aliyun.com/en/functioncompute/e2b-sdk-compatible-api-list)里：建、删、列、设超时、跑命令、读写文件、端口访问都兼容；
  **暂停要申请白名单**，恢复用 `connect`（没有单独的恢复接口）；超时被回收的沙箱连不上。快照、卷、自定义域名不支持。
  文档没写暂停最长保留多久、暂停怎么收费、超时到期能不能自动暂停——这几条正好是第 6 节要实测的，也要问阿里云。
- **对我们的影响**：架构里“空闲 10 分钟暂停、7 天内唤醒”靠暂停。白名单开不了、或暂停保留不到 7 天，就要改成第 5 节说的“删沙箱前把工作区存进 OSS、下次重建时放回”。

## 8.8 无影 AgentBay（2026-10-28 调研，这次不用）

结论：10 人测试的 agent 沙箱**不用** AgentBay，继续用东京 ACS 的 Agent Sandbox。以后做“云浏览器 / 云电脑”这类功能时，
可以由东京的服务端调它的接口，当成 agent 的一个平台工具（不进沙箱那一层；那时优先用国际站新加坡）。不用它的原因：

- **东京用不了**：国内站账号只能用中国大陆（SDK 默认杭州）；新加坡、美东只给国际站。东京、香港查不到。
- **Linux 沙箱锁不住出网**：域名白名单“目前仅支持 Windows 沙箱”，`*.aliyuncs.com` 始终放行；自建 VPC 只在杭州。
  多租户隔离的底线（出网只到模型网关）过不了。
- **装我们自己的 agent 要 Pro 档**（自定义镜像，¥999/月），规格最小 2 核 4G。
- **生命周期对不上**：单次运行最长 1000 分钟、休眠最长 72 小时；我们要等审批 24 小时、暂停保留 7 天。
- 命令接口没有 stdin（只能用交互终端凑），不是 E2B 接口，要新写沙箱后端（估 1.5–3 周）。

它的好处：Basic 档免费、10 个并发，CPU ¥0.12/核/时、内存 ¥0.05/GB/时按秒计；新用户送约 200 小时。
来源：help.aliyun.com/zh/agentbay（计费说明 2026-06-24、安全白皮书 2026-10-13、镜像设置 2026-04-28）、
github.com/agentbay-ai/wuying-agentbay-sdk（0.22.x）。

## 8.9 10 个测试用户的省钱方案（2026-10-28 估算）

假设每人每天 agent 跑约 1 小时（每月约 300 沙箱小时），不同时在线。两种办法，以后扩容都不用搬家：

| 项目 | 规格 | 每月 |
|---|---|---|
| 服务机 | `ecs.e-c1m2.large`（2 核 4G，经济型）包月 ¥117.67，按量 ¥0.2534/时 | ¥118 |
| 磁盘 | 40G 系统盘 + 20G 数据盘（放 Postgres） | 约 ¥22 |
| 数据库 | Postgres 16 装在服务机上（以后 pg_dump 搬到 RDS，改 DATABASE_URL 就行） | ¥0 |
| 公网流量 | 按流量 ¥0.6/GB，10–20 GB | ¥6–12 |
| 沙箱管理组件 | 测试配置约 1.2 核 2G | ¥142–146 |
| 沙箱运行 | 1 核 2G 每小时约 ¥0.25 × 300 小时（流量代理边车可能让规格进位，未实测） | ¥75–112 |
| 其他 | 快照、OSS、域名 | ¥15–25 |

- **办法一（最省，约 ¥390–450/月）**：沙箱用完最多休眠 1 小时就删，工作区存 OSS，下次重建放回。要多写 3–5 天代码。
- **办法二（最省事，约 ¥730–800/月）**：沙箱一直休眠。**休眠不收 CPU 和内存，但 30 GiB 临时存储照收**，每个约 ¥36/月。
- 都要做：预热池设 0（留 1 个每月 ¥135–270）；不开 SLS；不要 NAT、ALB；API Server 的 EIP 用不上，可以解绑（约 ¥22/月）。
- 都要先写的代码：Rust 的 ACS 沙箱后端（私有协议，2–3 天）；模型网关按沙箱 IP 绑定令牌（0.5 天）。第 6 节实测全部通过才上线。
- 第 2 节有两处估低了：4 核 8G 的 u1 官方标价 ¥627/月；“休眠只收存储”没算 30 GiB 的最低计费。
- 现在就要定对的：地域东京、服务机放在 ACS 集群的 VPC 里、不用轻量应用服务器或抢占式实例放服务和数据库。

来源：ECS 价格表 g.alicdn.com/aliyun/ecs-price-info/2.0.483（2026-10-22）、ACS 计费规则和临时存储说明（help.aliyun.com/zh/cs）。

**要请法务看的（和选哪家沙箱无关）**：Anthropic 的支持地区政策（anthropic.com/supported-countries，2026-11-12 生效）
不允许注册地、总部在不支持地区（含中国大陆、香港）或被这类公司控股的公司使用；Claude Code 的托管条款要求每个终端用户用自己的
凭证、平台不能替用户付费或中转用量（code.claude.com/docs/en/legal-and-compliance）。我们是“用户自带 Key、经网关转发”，
算不算中转要确认（`docs/licenses.md` 第 1 节也记着）。

## 9. 接手（新会话）

先读 [交接文档](handoff.md)（2026-10-28，东京、容器版的下一步都在那里）。

开新会话读 Key 时：先看本文件和 `docs/progress/claude-determined-lovelace-vn0j5h.md`，然后跑只读检查：

```sh
deploy/aliyun/run.sh check        # 第一次会在 target/aliyun-venv 装阿里云 SDK，约半分钟
deploy/aliyun/run.sh sandbox      # 有 ALIYUN_SANDBOX_API_KEY 时：只读看接口和模板；加 --apply 建 1 个沙箱测完删掉
```

它查 Key 和身份（应是 RAM 子账号，不是主账号）、新加坡有没有服务机的 4 核 8G 规格、VPC、RDS 的 PostgreSQL 16、OSS、ACS、账户余额，
只调查询接口、不建资源、不打印密钥；不通过的项会说该去哪儿处理（缺哪条权限、哪个产品没开通）。2026-10-27 只用假 Key 测过错误路径
（7 项都能连到阿里云、提示正确），成功路径第一次用真 Key 时核对输出。全部通过后从第 4 节第 1 阶段开始：先列资源和费用请用户确认，
再动手。每完成一个阶段，在本文件和进度文件里记一笔、提交推送。

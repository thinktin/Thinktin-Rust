# 交接：阿里云部署（2026-10-28）

上一个会话（session_01JYVuTJTo78Zrenhct8Bkw5）用量快满了，下一个 agent 从这里接着干。分支是 `claude/determined-lovelace-vn0j5h`，
PR #14 是开着的（部署脚本和文档）。**用户说“合并”才合。**

10-28 接手的会话（session_016LgPcdynywrhrjCq8VVFLt）环境里没有阿里云的 Key（会话比环境变量早），只做了不要 Key 的部分：
容器版的脚本 `deploy/aliyun/acs.py`、`sandbox.py --acs`，评审修了一轮，并且发现**云端会话连不上 ACS 集群的 API Server**
（见第 3 节）。用户换好国内站的 Key 后要**开新会话**才读得到。

**10-28 后半天（同一个会话）把代码写完了**（用户定：“1、省钱；2、解绑；3、写”）：

- Rust 的 ACS 沙箱后端 `AcsProvider`（OpenKruise 私有协议，`crates/sandbox/src/acs.rs`），模型网关的令牌绑到每个沙箱的
  Pod IP；空闲计时可配（`[sandbox.lifecycle]`）；没有卷时把工作区加密打包存 OSS、重建时放回（`[sandbox.workspace] mode = "object"`，
  迁移 0023）；东京的部署配置 `deploy/k8s/overlays/tokyo`。说明在 [ACS 后端](sandbox-acs.md)，实测清单在它第 8 节。
- 都只对着模拟服务和本机测过，**没连过真集群**。API Server 的 EIP 已解绑，EIP 本身还在收钱，要用户在控制台释放。
- 本机磁盘小：`~/.cargo/config.toml` 里开发构建只留行号调试信息、不做增量（新容器要重设，不进仓库）。

和用户说话用中文、说人话，用户不是做底层技术的。用户想让 Claude 在云端全面负责部署，自己只做“只能本人点”的事。

## 1. 规矩（必须遵守）

- **密钥**：
  - 不让用户把 Key、令牌、密码贴进聊天，不打印 Key，不提交 Key。
  - Key 只放在云端环境设置的**环境变量**里，不放设置脚本，也不放 Network secrets。
  - 生成的密钥（比如沙箱的 adminApiKey、kubeconfig）只放 `target/` 下（已被 `.gitignore` 忽略）。
- **花钱前先确认**：要收费的资源先列清单和费用，用户同意了再建。不收费的（VPC、交换机、安全组）可以直接建。
- **不绕过拦截**：自动模式的分类器拒绝过“开新会话去建云资源”。不要绕，云资源只在用户正在对话的会话里、经用户明确同意后建。
- **别唠叨**：用户已经说过“你别管了”，不要再提“轮换阿里云 Key”和“作废 Codemagic 令牌”。
- **小步提交、马上推送**：`git push -u origin claude/determined-lovelace-vn0j5h`。每做完一步就更新本文件和 `docs/deploy-aliyun-sg.md` 第 8.6 节。
- 提交信息里不写模型名。

## 2. 已经定下来的

| 事项 | 决定 |
|---|---|
| 账号 | **国内站 aliyun.com**（用户 10-28 换的；国际站要证件实名太慢） |
| 地域 | **日本东京 `ap-northeast-1`，可用区 a**（10-28 改的，原计划新加坡） |
| 沙箱 | **ACS 的 Agent Sandbox 容器版**。不用极速版（只留作备选），不部署 Cube |
| 模型 | App 直连 Claude、GPT、Grok、Gemini 等厂商，所以服务器放境外 |
| 其余 | 见 `docs/deploy-aliyun-sg.md` 第 0 节（文件名还叫 sg，内容按东京理解，顶上有说明） |

东京已经查过（只读）：

- ACS 的 1.36.2、1.35.7、1.34.10 三个版本都有沙箱组件：`ack-agent-sandbox-controller` v0.6.6-release.5，`ack-sandbox-manager` v0.6.13-release.1。
- 4 核 8G 的 `ecs.u1-c1m2.xlarge` 在可用区 a、b、c。
- RDS PostgreSQL 16 在可用区 a、b。

## 3. 现在卡在哪

用户正在**国内站控制台**的东京地域建 ACS 集群，K8s 版本选 `1.36.2-aliyun.1`。上个会话建议的选项：

- 新建 VPC，可用区 A；
- **不勾** SNAT / NAT 网关；
- **勾上**“用 EIP 暴露 API Server”（让我们从云端连集群）；
- 日志服务、Prometheus、事件中心都不勾；
- 不装 Ingress。

**10-28 发现的限制：云端会话连不上集群的 API Server。** 会话的出网代理只放行 443 端口的 HTTPS，不支持非 443 端口、客户端证书
和 WebSocket（`/root/.ccr/README.md`，规定是“报告，不要绕过”）。API Server 在 6443、kubeconfig 用客户端证书、port-forward
要 WebSocket，三样都不行（10-28 实测 8443 端口被代理断开）。所以：

- “用 EIP 暴露 API Server”对我们没用（勾了的话 EIP 在收一点钱，以后可以解绑）。
- 阿里云的 OpenAPI 走 443，能用：找集群、装沙箱组件（`run.sh acs --addons`）都在云端会话里做。
- 要 kubectl 的（建预热池、port-forward 测沙箱）得在**集群 VPC 里的一台机器**上跑。建议：把计划里的服务机 ECS 提前建在集群的
  VPC 里（本来就要带按流量的公网 IP，能自己下 kubectl 和 Python 包），用 ECS 云助手（RunCommand，也走 443 的 OpenAPI）在它上面跑
  `run.sh acs --pool` 和 `run.sh sandbox --acs`，读回输出。ECS 要收费，**先列费用、用户同意再建**；云助手的驱动脚本还没写。
  另一条路是给 sandbox-manager 配 ALB + 域名 + 证书从公网连，正式环境用不上（服务机在 VPC 里直接连），不推荐。

建好后，用户要做这几件事：

1. 在**国内站账号**的 RAM 里建子账号 `thinktin-deploy`，只开 OpenAPI 调用，授权以下策略，然后建 AccessKey：
   - `AliyunECSFullAccess`
   - `AliyunVPCFullAccess`
   - `AliyunRDSFullAccess`
   - `AliyunOSSFullAccess`
   - `AliyunCSFullAccess`
   - `AliyunContainerRegistryFullAccess`
   - `AliyunBSSReadOnlyAccess`
2. 把云端环境“环境变量”里的 `ALIBABA_CLOUD_ACCESS_KEY_ID` 和 `ALIBABA_CLOUD_ACCESS_KEY_SECRET` **换成新账号的**，变量名不变。
   （用户 10-28 说已经换了。）
3. 开新会话。环境变量只在虚拟机启动时读，老会话读不到新值。
4. 到 kubectl 那一步时：ACS 控制台 → 授权管理 → RAM 用户 `thinktin-deploy` → 选这个集群、所有命名空间、**管理员**。
   RAM 的策略只管 OpenAPI，集群里面的权限要单独给，不然 kubectl 报 Forbidden。

**现在环境变量里还是国际站账号的 Key。** 那个账号在新加坡建过一套不收费的网络（ID 见部署文档第 8.6 节），以后经用户同意删掉。

## 4. 下一步（按顺序）

脚本都在 `deploy/aliyun/`，默认东京，花钱的都要加 `--apply`，不加只打印计划和费用估算。

1. **确认新 Key**：`deploy/aliyun/run.sh check`（默认东京）。**10-28 全部通过**（子账号 `claude-deploy`，用户给了
   `AdministratorAccess`），但**余额 0.00 元**：国内站是预付，付费资源下单前要用户充值。
   - 身份应该是新账号的 RAM 子账号；余额要大于 0（国内站是预付，没充值的话付费资源会下单失败）。
   - 第一次跑会在 `target/aliyun-venv` 装 SDK，约半分钟。
2. **看集群和组件**（云端会话里，只读）：`run.sh acs`。
   - 找东京的集群（不止一个就加 `--cluster`），打出 API Server 的内网、公网地址，列两个沙箱组件装没装、可装的版本、
     配置项（schema 存在 `target/aliyun-acs/`）。
3. **装沙箱组件**（云端会话里，要收费）：先 `run.sh acs --addons`，看打印的配置（Key 打码）和费用估算。
   - 东京集群（10-28 建好，`Thinktin-Rust`，ACS 1.36.2）可装 `ack-agent-sandbox-controller` v0.6.6-release.5、
     `ack-sandbox-manager` v0.6.13-release.1。sandbox-manager 不改配置的话是 sandbox-manager 3 个 × 8 核 8G、
     sandbox-gateway 3 个 × 4 核 8G、日志进 SLS，约 36 核 48G、**每月约 ¥3,900**。
   - 测试配置（`acs.py` 的 `manager_config`，按真实配置项名逐项改）：domain `localhost`、adminApiKey 自己生成（`e2b_` 加十六进制）、
     关 TLS、**数据面也走 sandbox-manager**（`ingress.dataplaneService`，port-forward 只转发它）、两边各 1 个副本 0.5 核 1G、不收日志。
     估算约 1.2 核 2G、**每月约 ¥146**。控制器用默认配置（它给每个沙箱加的流量代理 0.2 核 128M 另算）。
   - 用户同意后 `run.sh acs --addons --apply`。第一次装控制器要在控制台授权 `AliyunCSManagedAgentSandboxRole`，失败就请用户去点。
   - Key 存在 `target/aliyun-acs/sandbox.json`，容器回收丢了的话重跑 `--addons` 会从已装组件的配置里读回来，不会换新的。
   - sandbox-gateway 的 `streamIdleTimeout` 默认 600 秒：正式环境 agent 等审批可能几个小时没输出，要看它和 sandbox-manager 的超时。
   - 参考：<https://help.aliyun.com/zh/cs/user-guide/connect-to-agent-sandbox-using-the-e2b-sdk>
4. **请用户定 kubectl 在哪儿跑**（见第 3 节），建议提前建服务机 ECS（集群的 VPC、按流量的公网 IP），列费用请用户同意。
   - 还要写一个用云助手在 ECS 上跑命令、读输出的小脚本（ECS 的 RunCommand / DescribeInvocationResults，云端会话能调）；
     把仓库的 `deploy/aliyun/` 传上去（文件小，云助手的 SendFile 就行，或者 ECS 直接从 GitHub 拉）。
   - 用户给 `thinktin-deploy` 开集群里的管理员权限（第 3 节第 4 条）。
5. **在 ECS 上建预热池**：`run.sh acs --pool`（只读，打印费用）→ 用户同意 → `run.sh acs --pool --apply`。
   - SandboxSet `code-interpreter`，命名空间 `default`，replicas 1，镜像默认 `registry-ap-northeast-1-vpc.ack.aliyuncs.com/acs/code-interpreter:v1.6`
     （文档示例的地域换成东京、走 VPC 地址；地址不对就用 `--image` 换）。
   - kubeconfig 用内网地址，存在 `target/aliyun-acs/kubeconfig`（1 天后失效）；kubectl 钉 v1.36.5、核对 SHA-256，放 `target/bin`。
   - 拉不下镜像（没有 NAT）先试 ACR 的 VPC 地址；不行再列 NAT 网关的费用请用户确认。不测了：`run.sh acs --pool-delete --apply`。
6. **在 ECS 上测沙箱**：`run.sh sandbox --acs`（只读，列现有沙箱）→ 用户同意 → `run.sh sandbox --acs --apply`。
   - 自己起 `kubectl port-forward` 到 sandbox-manager（本机 80 端口），走 OpenKruise 的私有协议（HTTP）。私有协议是
     `sandbox.py` 里的 `kruise_patch`（改 E2B SDK 的两个地址），**没装** OpenKruise 的 `kruise_agents` 包：从 GitHub 装它被
     自动审查拦了（外部代码），功能就这两处地址，自己写了。
   - E2B SDK 钉 `e2b==2.50.0`、`e2b-code-interpreter==2.9.2`（文档要求；2.51 起建、连沙箱走 v2 接口，容器版不认）。
   - 测：冷启动多久、给了几核几 G；读写文件；元数据地址 `100.100.100.200`（应该不通）；**两个沙箱之间通不通**（应该不通，
     先在 A 起监听、A 自己连通了才作数）；出网（没有 NAT 应该不通）；暂停（`beta_pause`）、恢复（`connect`）、文件还在不在；
     300 秒没输出会不会被断（`--idle`）。收尾按标记删掉这次建的所有沙箱。
   - 云端会话里跑 `sandbox --acs` 会直接说连不上，不会去试。
7. **记结果**：写进部署文档第 8.6 节，提交、推送。
   - 问用户集群留不留：一直在收钱的有组件的容器、预热池的 1 个沙箱、（如果勾了的）API Server 的 EIP。
8. **后面的阶段**：RDS、OSS、正式用的 ALB、域名、证书，都是**先列费用、用户同意再建**。顺序见部署文档第 4 节。
   - 第 1 阶段网络 `run.sh network` 改成默认东京、**用 ACS 集群的 VPC**（服务机、数据库、沙箱在一个 VPC 里），只在里面加服务机的
     交换机（自动挑空的 /24）和安全组；地域里没有集群时才自己建 VPC。新加坡那套（国际站账号）以后经用户同意删掉。

9. **代码已写好，部署时要定的（问用户）**：
   - 服务机怎么访问 sandbox-manager：ACS 没有节点，要用内网负载均衡把它暴露到 VPC（收费，先查价），或者后台副本挪进集群。
   - 计时：东京配置是空闲 10 分钟暂停、暂停 1 小时删沙箱存 OSS；有计划的也归档、到点前 5 分钟建好；等审批时沙箱一直开着
     （每小时约 ¥0.25，暂停后 agent 进程能不能接上要实测）。
   - 工作区归档只留最新一份、删实例就删；隐私政策要写“工作区存在东京 OSS”。超过 4 GiB 的不归档、一直暂停着收存储费（2026-10-28 用户定：测试阶段保持 4 GiB，临时空间默认 9 GiB 不改）。
   - 集群内是明文 HTTP（sandbox-manager、envd、模型网关之间）；10 人测试先接受？沙箱交换机的安全组只放行服务机的 8790（不收费）。
   - 实测要一台在集群 VPC 里的机器（就是服务机），收费，先列价。

**10-28 用户定**：先按 10 个测试用户上线，便宜优先，以后再加。AgentBay 调研过了、这次不用；省钱方案见部署文档第 8.8、8.9 节。
余额 ¥15（用户充的），花钱前照样先列费用问用户。

## 5. 其他线（不急）

- **iOS、安卓、macOS、后端**：能在代码里做完的都做完了，已经合到 main（PR #6、#9 到 #13）。各线进度在 `docs/progress.md`、`docs/progress/*.md`。
- **agent 之间互相通信（8.9–8.12）、项目和跨用户协作（8.13–8.19）**：只写了设计（`docs/architecture-v3.md` 4.11 节、`docs/projects.md`）。**用户说先不开干。**
- **事件触发还没做**：`ScheduleSpec` 只有 Cron、Rrule、Once；IM 机器人只能往外发，收不到消息。
- **上架国内商店要 App 备案**：后端只在境外一般办不了，见部署文档第 7 节。现在的计划是先不上国内商店。

## 6. 环境里要知道的

- 出网走代理，`SSL_CERT_FILE` 已经设好，阿里云 Python SDK 和 e2b SDK 都能用。
- `deploy/aliyun/run.sh <check|network|acs|sandbox>`：自动建 venv，按 `requirements.txt` 装依赖（只从 PyPI 装钉死的版本）。
  不加 `--apply` 只打印计划；按名字找资源，重跑不会重复建。
- 云端会话**只能连 443 端口的 HTTPS**：阿里云 OpenAPI、OSS 能用；集群的 API Server（6443）、kubectl、port-forward 不行。
- 每小时的定时任务“Thinktin 后端自动续跑”（`trig_01KGPvNBHsmuQxk3phCmsUaE`）还在叫醒老的后端会话，提示词过时了，那边直接跳过；
  停不停由用户定。
- `git push` 删不了远程分支（代理返回 403），删分支要用户在网页上操作。
- 想盯 PR #14 的话，先 `subscribe_pr_activity`。

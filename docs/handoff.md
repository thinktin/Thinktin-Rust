# 交接：阿里云部署（2026-10-28）

上一个会话（session_01JYVuTJTo78Zrenhct8Bkw5）用量快满了，下一个 agent 从这里接着干。分支是 `claude/determined-lovelace-vn0j5h`，
PR #14 是开着的（部署脚本和文档）。**用户说“合并”才合。**

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
3. 开新会话。环境变量只在虚拟机启动时读，老会话读不到新值。

**现在环境变量里还是国际站账号的 Key。** 那个账号在新加坡建过一套不收费的网络（ID 见部署文档第 8.6 节），以后经用户同意删掉。

## 4. 下一步（按顺序）

1. **确认新 Key**：跑 `deploy/aliyun/run.sh check --region ap-northeast-1`。
   - 身份应该是新账号的 RAM 子账号。
   - 第一次跑会在 `target/aliyun-venv` 装 SDK，约半分钟。
   - 余额要大于 0；国内站是预付，没充值的话付费资源会下单失败。
2. **找到集群**：用 CS 的 `DescribeClustersV1` 查东京的集群。
   - 用 `DescribeClusterUserKubeconfig` 拿公网的 kubeconfig，存到 `target/`，不要打印。
   - kubectl 要自己装：下载固定版本的二进制到 `target/bin`。
   - 如果 API Server 没开公网，就告诉用户，或者经用户同意后绑一个按流量计费的 EIP。
3. **装沙箱组件**：用 CS 的 `InstallClusterAddons` 装 `ack-agent-sandbox-controller` 和 `ack-sandbox-manager`。
   - 先用 `DescribeAddon` 看配置项长什么样。
   - 测试不要 Ingress，TLS 关掉。
   - `adminApiKey` 自己生成，格式要是 `e2b_` 加十六进制（比如 `"e2b_" + secrets.token_hex(20)`），存到 `target/`。
   - 参考：<https://help.aliyun.com/zh/cs/user-guide/connect-to-agent-sandbox-using-the-e2b-sdk>
4. **预热池**：kubectl apply 一个 SandboxSet，名字叫 `code-interpreter`，命名空间 `default`，**replicas 设 1**（文档例子是 4，测试用 1 省钱）。
5. **连上沙箱管理器**：跑 `kubectl port-forward services/sandbox-manager 8080:7788 -n sandbox-system`，走私有协议的 HTTP。
   - 客户端要装 openkruise 的补丁包 `git+https://github.com/openkruise/agents.git#subdirectory=sdk/customized_e2b`（钉到某个提交）。
   - **在 import e2b 之前**调用 `patch_e2b(https=False)`。
   - `E2B_DOMAIN` 设成和组件里的 domain 一样。
   - 文档配的版本是 `e2b==2.50.0`、`e2b-code-interpreter==2.9.2`。`deploy/aliyun/requirements.txt` 现在钉的是给极速版用的 2.31.0，要改。
6. **改测试脚本** `deploy/aliyun/sandbox.py`：现在它只会连极速版的地址。
   - 加容器版模式：补丁、域名、Key 从 `target/` 读。
   - 容器版的暂停是 `beta_pause`，恢复用 `connect`。
   - 然后按部署文档**第 6 节**逐条测：
     - 冷启动多久，给了几核几 G；
     - 读写文件；
     - 连不连得上元数据地址 `100.100.100.200`（应该连不上）；
     - **建两个沙箱，测它们之间通不通**（应该不通）；
     - 出网（没有 NAT，应该连不上外网；正式环境沙箱只连服务机上的模型网关）；
     - 暂停、恢复，文件还在不在；
     - 长时间没输出会不会被断。
7. **记结果**：写进部署文档第 8.6 节，提交、推送。删掉测试沙箱。
   - 问用户集群留不留：一直在收钱的有组件的容器、预热池的 1 个沙箱、EIP。
8. **后面的阶段**：服务机 ECS（k3s）、RDS、OSS、正式用的 ALB、域名、证书，都是**先列费用、用户同意再建**。顺序见部署文档第 4 节。

如果沙箱拉不下镜像（没有 NAT 出不去），先看能不能用 ACR 的 VPC 地址；不行再列 NAT 网关的费用请用户确认。

## 5. 其他线（不急）

- **iOS、安卓、macOS、后端**：能在代码里做完的都做完了，已经合到 main（PR #6、#9 到 #13）。各线进度在 `docs/progress.md`、`docs/progress/*.md`。
- **agent 之间互相通信（8.9–8.12）、项目和跨用户协作（8.13–8.19）**：只写了设计（`docs/architecture-v3.md` 4.11 节、`docs/projects.md`）。**用户说先不开干。**
- **事件触发还没做**：`ScheduleSpec` 只有 Cron、Rrule、Once；IM 机器人只能往外发，收不到消息。
- **上架国内商店要 App 备案**：后端只在境外一般办不了，见部署文档第 7 节。现在的计划是先不上国内商店。

## 6. 环境里要知道的

- 出网走代理，`SSL_CERT_FILE` 已经设好，阿里云 Python SDK 和 e2b SDK 都能用。
- `deploy/aliyun/run.sh <check|network|sandbox>`：自动建 venv，按 `requirements.txt` 装依赖。`network` 默认只打印计划，加 `--apply` 才建；按名字找资源，重跑不会重复建。
- `git push` 删不了远程分支（代理返回 403），删分支要用户在网页上操作。
- 想盯 PR #14 的话，先 `subscribe_pr_activity`。

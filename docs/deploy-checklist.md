# 部署环境准备清单（预发、生产）

给准备环境的人看：要建哪些云资源、要申请哪些账号、密钥怎么生成、配置填到哪、第一次上线按什么顺序。
发布流程本身（迁移、灰度、回滚）见 [发布流程](release.md)，沙箱集群的细节见 [CubeSandbox 后端](sandbox-cube.md)，
设备中继见 [设备中继](relay.md)。

**先办，要等的**（审核要几天到几周，和建资源同时开始）：ICP 备案（对外域名）、阿里云短信的签名和验证码模板、
生成式 AI 登记（[合规](compliance.md)）、Apple 开发者账号、极光推送应用（如果安卓推送定了用极光）。

## 1. 云资源（每个环境一套，不共用）

| 资源 | 做什么 | 建议 | 填到哪 |
|---|---|---|---|
| Kubernetes（阿里云 ACK） | 四个服务：接口 `thinktin-api`、后台 `thinktin-worker`、模型网关 `thinktin-llm-gw`、设备中继 `thinktin-relay`；迁移 Job | 生产每个服务 2 个副本（预发 1 个）。请求 / 上限：接口、后台、模型网关 250m CPU、256Mi / 1Gi 内存；中继 100m、128Mi / 512Mi。另留灰度副本的余量 | 命名空间 `thinktin-staging`、`thinktin` |
| PostgreSQL 16（RDS） | 唯一的数据库 | 连接上限 > 副本数 × 20（`server.toml` 的 `database.max_connections`）+ 模型网关、中继、迁移的连接；开自动备份 | 各 Secret 的 `DATABASE_URL`（第 3 节） |
| 对象存储（OSS，S3 兼容） | 产出物（按用户加密后存） | 一个桶，私有；服务走内网地址 | `server.toml` 的 `[storage.s3]` |
| KMS 主密钥（阿里云 KMS） | 包裹每个用户的数据密钥 | 一把对称主密钥，起别名（预发、生产各一把） | `[kms.aliyun]` 的 `key_id` |
| 短信（阿里云短信） | 登录验证码 | 签名 + 验证码模板（要审核） | `[sms.aliyun]` 的 `sign_name`、`template_code` |
| CubeSandbox 集群 | agent 的沙箱 | 在 ACK 之外的云主机上（PVM 模式），按 Cube 的部署文档；开卷插件（`volume_driver`）；沙箱出网只放行模型网关 | `[sandbox.cube]`：`api_url`、`proxy_url`、`egress_address`；CubeAPI 开了鉴权时 `THINKTIN_CUBE_API_KEY` |
| 内网负载均衡 | Cube 节点上的沙箱访问模型网关（不对公网） | 指向 `thinktin-llm-gw` 的 8790 端口 | `[sandbox]` 的 `gateway_url`、`network_allow` |
| 公网负载均衡 / Ingress + TLS | App 访问接口（https）、电脑连中继（wss） | 两个域名（比如 `api.…`、`relay.…`）；支持 WebSocket，空闲超时 > 20 秒（中继心跳） | App 的接口地址（iOS `THINKTIN_API_BASE_URL`、安卓 `BASE_URL`）；电脑的中继地址 |
| 镜像仓库 | 服务镜像、agent 模板镜像 | 默认 ghcr.io；用阿里云 ACR 时设仓库变量 `IMAGE_REGISTRY`、`IMAGE_NAMESPACE` 和两个 secret（见 `.github/workflows/release.yml`） | GitHub 仓库设置 |
| 监控 | 指标（每个服务的 9090 端口，Prometheus 格式）、日志（JSON） | Prometheus + Grafana（或云监控）抓 `/metrics`；日志采集 | 灰度时看的指标见 [发布流程](release.md) 第 4 节 |

Redis：WBS 2.5 里列了，现在的代码没用到，可以先不建。

## 2. 账号和第三方

| 账号 | 要什么 | 填到哪 |
|---|---|---|
| 阿里云 RAM 子账号 | 只给 KMS（加解密这把主密钥）、短信、OSS（这个桶）的权限，各一对 AccessKey | Secret：`THINKTIN_ALIYUN_KMS_ACCESS_KEY_*`、`THINKTIN_ALIYUN_SMS_ACCESS_KEY_*`、`THINKTIN_S3_*` |
| Apple 开发者 | APNs 推送密钥（.p8）、Team ID、Key ID；App 的 bundle id；App Store Connect API 密钥（TestFlight 发版） | `[push.apns]`、Secret `thinktin-push` 的 `apns.p8`；GitHub 的 `testflight` 环境（[iOS 发版](ios-release.md)） |
| 极光推送（安卓，如果定了用它） | AppKey、Master Secret | `[push.jpush]` 的 `app_key`、Secret `thinktin-worker` 的 `THINKTIN_JPUSH_MASTER_SECRET` |
| Firebase（海外安卓，可选） | 服务账号 JSON | Secret `thinktin-push` 的 `fcm.json` |
| 安卓签名 | release 签名的 keystore | [安卓发版](android-release.md) |
| 审核用的手机号（提交商店审核时） | 一个没人用的号和 6 位固定码 | `[api]` 的 `review_phone`、`THINKTIN_REVIEW_CODE`（审核过了删掉） |

## 3. 密钥

每个环境生成一套（预发、生产不共用）：

```sh
docker run --rm <镜像仓库>/thinktin-server:<版本> gen-secrets
# 或者在仓库里：cargo run -p server -- gen-secrets
```

打印出访问令牌、沙箱令牌的签名种子、验证码密钥、四个数据库账号的密码，和要填进 ConfigMap 的两个公钥。
密钥只显示这一次，存进密码管理器。

**数据库账号**（用 RDS 的高权限账号执行）：

```sql
CREATE ROLE thinktin_owner LOGIN PASSWORD '<thinktin_owner 的密码>';   -- 表的属主，只给迁移 Job
CREATE DATABASE thinktin OWNER thinktin_owner;
-- 服务用的四个角色。迁移里也会建，但建 BYPASSRLS 的角色要超级用户（或者自己有 BYPASSRLS），托管数据库的属主
-- 账号通常没有，所以在这里先建好，迁移遇到已有的就跳过。
CREATE ROLE thinktin_app NOLOGIN NOBYPASSRLS;
CREATE ROLE thinktin_worker NOLOGIN BYPASSRLS;
CREATE ROLE thinktin_llmgw NOLOGIN BYPASSRLS;
CREATE ROLE thinktin_relay NOLOGIN BYPASSRLS;
-- 三个服务的登录账号，只拿对应角色的成员身份。
CREATE ROLE thinktin_server_login LOGIN PASSWORD '…';
GRANT thinktin_app, thinktin_worker TO thinktin_server_login;
CREATE ROLE thinktin_llmgw_login LOGIN PASSWORD '…';
GRANT thinktin_llmgw TO thinktin_llmgw_login;
CREATE ROLE thinktin_relay_login LOGIN PASSWORD '…';
GRANT thinktin_relay TO thinktin_relay_login;
```

高权限账号也建不了 `BYPASSRLS` 的角色时先停下来告诉开发：后台、模型网关、中继要跨用户读写（领运行、查路由、
转消息），要改成按角色写行级策略。

**Secret**（键就是环境变量名，完整的表见 [发布流程](release.md) 第 5 节）：

```sh
ns=thinktin-staging
db=rm-xxxx.pg.rds.aliyuncs.com:5432/thinktin
kubectl -n $ns create secret generic thinktin-migrate --from-literal=DATABASE_URL="postgres://thinktin_owner:…@$db"
kubectl -n $ns create secret generic thinktin-api \
  --from-literal=DATABASE_URL="postgres://thinktin_server_login:…@$db" \
  --from-literal=THINKTIN_ACCESS_TOKEN_SEED=… --from-literal=THINKTIN_CODE_PEPPER=… \
  --from-literal=THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID=… --from-literal=THINKTIN_ALIYUN_KMS_ACCESS_KEY_SECRET=… \
  --from-literal=THINKTIN_S3_ACCESS_KEY_ID=… --from-literal=THINKTIN_S3_SECRET_ACCESS_KEY=… \
  --from-literal=THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID=… --from-literal=THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET=…
kubectl -n $ns create secret generic thinktin-worker \
  --from-literal=DATABASE_URL="postgres://thinktin_server_login:…@$db" \
  --from-literal=THINKTIN_SANDBOX_TOKEN_SEED=… \
  --from-literal=THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID=… --from-literal=THINKTIN_ALIYUN_KMS_ACCESS_KEY_SECRET=… \
  --from-literal=THINKTIN_S3_ACCESS_KEY_ID=… --from-literal=THINKTIN_S3_SECRET_ACCESS_KEY=… \
  --from-literal=THINKTIN_CUBE_API_KEY=… --from-literal=THINKTIN_JPUSH_MASTER_SECRET=…
kubectl -n $ns create secret generic thinktin-push --from-file=apns.p8 --from-file=fcm.json
kubectl -n $ns create secret generic thinktin-llm-gw \
  --from-literal=DATABASE_URL="postgres://thinktin_llmgw_login:…@$db" \
  --from-literal=THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID=… --from-literal=THINKTIN_ALIYUN_KMS_ACCESS_KEY_SECRET=…
kubectl -n $ns create secret generic thinktin-relay --from-literal=DATABASE_URL="postgres://thinktin_relay_login:…@$db"
```

命令会留在 shell 历史里：在干净的终端里执行，或者用云的密钥管理（KMS 凭据、外部密钥同步）代替。

## 4. 填配置

`deploy/k8s/overlays/<环境>/` 里标了“部署前填”的地方：

- `server.toml`：`[sandbox]` 的模型网关内网地址；`[sandbox.cube]`；`[storage.s3]` 的地址、桶；`[kms.aliyun]`；
  `[sms.aliyun]`；`[push.apns]` 的 `team_id`、`key_id`（`topic` 是 App 的 bundle id）；`[push.jpush]` 的 `app_key`；
  备案后 `[compliance]` 的 `content_producer` 换成正式的服务提供者编码。
- `kustomization.yaml`：`gen-secrets` 打印的两个公钥（`THINKTIN_SANDBOX_TOKEN_KEY`、`THINKTIN_ACCESS_TOKEN_KEYS`）。

填完跑 `cargo test -p server deployment_configs_are_valid`（CI 也跑），确认能解析、按两种角色都通过校验。

## 5. 第一次上线（预发）

1. 打版本标签（`v0.1.0`），等 Release 工作流推好镜像、生成部署包（GitHub Release 的附件）。
2. 建命名空间、第 3 节的数据库账号和角色、Secret。
3. 迁移：`kubectl apply -f thinktin-staging-migrate-<版本>.yaml`，等 Job 完成。
4. 服务：`kubectl apply -f thinktin-staging-<版本>.yaml`，`rollout status` 等四个服务就绪。
5. agent 模板：模板镜像（`templates.yml` 打标签时推送）在 Cube 里注册成模板（[模板](templates.md)、6.8）。
6. 冒烟：登录、领养一个 agent、对话一轮、建一个一分钟后的计划等它跑完、手机收到推送、电脑连上中继调一次电脑工具。

生产同样的顺序，迁移之后先灰度（[发布流程](release.md) 第 4 节）。

## 6. 环境好了以后（联调）

这些要在预发上做，环境好了以后接着做：

- Cube 联调：[CubeSandbox 后端](sandbox-cube.md) 第 5 节列的待确认项（envd 的接口细节、长连接保活、快照和卷）；
  常驻可靠性演练的预发部分（[演练报告](reliability-drill.md) 最后一节）。
- 压测：按 [压测说明](loadtest.md) 跑出正式数字，再配自动扩缩。
- 出网策略（2.7）：沙箱只能连模型网关；集群内的 NetworkPolicy。
- 客户端：把 App 的接口地址指到预发，跑一遍真机（推送、生物识别、Keystore、配对电脑）。

做联调要能连到预发：一个预发的接口地址和测试账号（手机号能收到验证码，或者临时配一个审核用的固定码），
需要看集群时给一个只读的 kubeconfig。

# 发布流程（WBS 2.9）

服务端怎么打版本、出镜像、迁移数据库、灰度上线、回滚。集群、数据库、对象存储这些环境本身见 2.2、2.3、2.5；
agent 的沙箱模板单独构建（6.8）；App 走各自的商店（12.11、13.11、14.9）。

## 1. 发布什么

同一个提交、同一个版本号出三个镜像（`deploy/docker/Dockerfile`，三个程序一次编译）：

| 镜像 | 程序 | 部署（`deploy/k8s`） |
|---|---|---|
| `thinktin-server` | 控制面：客户端接口、调度、执行、推送 | `thinktin-api`（只开接口）、`thinktin-worker`（只开后台任务），同一份配置，角色由环境变量 `THINKTIN_API_ENABLED`、`THINKTIN_WORKER_ENABLED` 决定；迁移 Job 也用它 |
| `thinktin-llm-gw` | 模型网关 | `thinktin-llm-gw`：用户 key 的明文只在这里，不对公网 |
| `thinktin-relay` | 设备中继 | `thinktin-relay`：电脑连上来的 wss |

运行时镜像是 distroless（只有 glibc、CA 证书和程序，没有 shell），以 nonroot（uid 65532）运行，根文件系统只读。
配置和密钥都从挂载的 ConfigMap、Secret 来，镜像里不放任何密钥。

## 2. 版本号和标签

- 版本号 `主.次.修订`，预发布加后缀（`0.3.0-rc.1`）。在 `main` 上打标签 `v<版本号>` 就开始发布
  （`.github/workflows/release.yml`）：构建 → 冒烟（每个程序报对版本、配置检查拒绝缺密钥的配置）→ 推镜像
  （标签 `<版本号>` 和 `sha-<提交>`，附构建来源证明和 SBOM）→ 生成部署包 → 建 GitHub Release。
- 镜像默认推到 `ghcr.io/<仓库属主>`。国内集群拉 ghcr.io 慢的话，仓库变量 `IMAGE_REGISTRY`、`IMAGE_NAMESPACE`
  改成阿里云容器镜像服务（ACR）的地址，用户名密码放 secret `IMAGE_REGISTRY_USERNAME`、`IMAGE_REGISTRY_PASSWORD`。
- 部署包是 GitHub Release 的附件，每个环境一份，镜像按摘要（`@sha256:…`）固定，标签被改指向也不影响：
  `thinktin-staging-<版本>.yaml`、`thinktin-staging-migrate-<版本>.yaml`、`thinktin-production-<版本>.yaml`、
  `thinktin-production-migrate-<版本>.yaml`、`thinktin-production-canary-<版本>.yaml`。
  想在预发上试某个提交，用 `deploy/k8s/bundle.sh` 按标签手动生成。
- 跑起来以后版本号在 `/version`、启动日志和指标 `thinktin_build_info{version="…"}` 里，灰度时据此区分新旧副本。
- 改了 `deploy/`、`.dockerignore` 或发布流程本身时，推到 `main`、`backend-core` 也会跑一遍（只构建、冒烟、
  校验清单，不推送）。

## 3. 数据库迁移

**先迁移、后换程序。** 迁移 Job 跑完，才更新程序；滚动更新、灰度、回滚的时候，新旧两版程序同时连着新的表结构。
所以每个迁移都要让**上一版程序照常工作**（扩展—收缩：先加，旧版本不用了再删）：

- 加列：可空，或者带默认值。加表、加索引随意（大表的索引见下）。
- 删列、删表、改类型：分两次发布。第一次发不再读写它的程序；下一次发布的迁移再删，删的语句前写
  `-- deploy-safe: <为什么上一版不受影响>`。
- 改名：不直接改。加新列 → 程序双写、回填 → 改成读新列 → 下一次发布删旧列。
- 加非空：先加可空列，程序开始写它、回填；下一次发布 `SET NOT NULL`（标 `deploy-safe`）。
- 收紧检查约束、收回权限：同样要确认上一版不会写出违反的数据、不再用这个权限，标 `deploy-safe`。
- 在已有的大表上建索引用 `CREATE INDEX CONCURRENTLY`，放在单独的迁移里，第一行写 `-- no-transaction`
  （sqlx 才不包事务）；普通的 `CREATE INDEX` 期间这张表写不进去。
- 发布过的迁移文件一个字节都不能改：sqlx 按内容的校验和核对，改了生产库就迁移不了、程序也拒绝启动。

**检查**：CI 的 `Migrations` 步骤（`tools/ci/check_migrations.py`）对照最近的 `v*` 标签：发布过的迁移改了、删了，
编号不连续，新迁移里有会让上一版程序出错的语句又没标 `deploy-safe`，都会失败；会长时间锁表的（已有的表上建索引、
加约束、全表更新）只提醒。还没打过标签时只查文件名。

**启动时核对**：控制面、模型网关、设备中继启动时把自己带的迁移和数据库里执行过的对比
（`store::Db::check_migrations`）。缺这一版要的迁移、执行了一半、发布过的被改过，都拒绝启动，日志里写明原因
（滚动更新停在第一个新副本上，老副本照常服务）；数据库比程序新（回滚到上一版）时记一条日志、照常启动。
`thinktin-server migrate` 在比它新的库上也不报错。开发环境可以 `migrate_on_start = true`，生产不开。

**账号**：迁移 Job 用表的属主账号（只有 Secret `thinktin-migrate` 里有）。服务各用自己的登录账号，
只拿对应角色的成员身份（角色由迁移 0001、0014 建好，`NOLOGIN`）：

```sql
CREATE ROLE thinktin_server_login LOGIN PASSWORD '…';   -- 控制面
GRANT thinktin_app, thinktin_worker TO thinktin_server_login;
CREATE ROLE thinktin_llmgw_login LOGIN PASSWORD '…';    -- 模型网关
GRANT thinktin_llmgw TO thinktin_llmgw_login;
CREATE ROLE thinktin_relay_login LOGIN PASSWORD '…';    -- 设备中继
GRANT thinktin_relay TO thinktin_relay_login;
```

登录账号要继承角色的权限（默认就是 `INHERIT`）：启动核对读 `_sqlx_migrations`，权限来自角色（迁移 0016）。托管数据库（RDS）的属主账号通常建不了 `BYPASSRLS` 的角色：用高权限账号先把四个角色建好，迁移遇到已有的会跳过
（[部署环境准备清单](deploy-checklist.md) 第 3 节）。

## 4. 上线步骤

**预发**（命名空间 `thinktin-staging`）：

```sh
kubectl apply -f thinktin-staging-migrate-0.3.0.yaml
kubectl -n thinktin-staging wait --for=condition=complete --timeout=15m job/thinktin-migrate-0-3-0
kubectl apply -f thinktin-staging-0.3.0.yaml
kubectl -n thinktin-staging rollout status deploy/thinktin-api deploy/thinktin-worker deploy/thinktin-llm-gw deploy/thinktin-relay
```

然后冒烟：登录、领养一个 agent、对话一轮、建一个一分钟后的计划等它跑完、手机收到推送、电脑连上中继调一次电脑工具。

**生产**（命名空间 `thinktin`）：

1. 迁移：同上，换成 `thinktin-production-migrate-<版本>.yaml`。迁移失败时程序不动，看 Job 的日志，修好以后删掉这个
   Job 再 apply。
2. 灰度：`kubectl apply -f thinktin-production-canary-<版本>.yaml`。四个服务各加一个新版本的副本
   （`*-canary`，标签 `track: canary`），按副本数分到一部分接口请求、电脑连接、模型请求，也领一部分运行。
   看 30 分钟以上，新旧版本对比（Prometheus 按 Pod 的 `track` 标签或 `thinktin_build_info` 区分）：
   - 接口：`thinktin_http_requests_total` 里 5xx 的比例、`thinktin_http_request_seconds` 的 p99；
   - 运行：`thinktin_run_attempts_total` 按结果的比例、`thinktin_run_attempt_seconds`；
   - 推送：`thinktin_push_total` 失败的比例；IM 群消息：`thinktin_im_total`（`dropped` 多半是用户的机器人设置不对，看渠道的 `last_error`）；
   - 模型网关：`thinktin_llm_requests_total` 按状态、`thinktin_llm_rejections_total`；
   - 中继：`thinktin_relay_disconnects_total`、`thinktin_relay_calls_total` 按结果；
   - 日志里 `ERROR` 的数量。
3. 全量：`kubectl apply -f thinktin-production-<版本>.yaml`，`kubectl -n thinktin rollout status …` 等四个服务
   换完，再 `kubectl delete -f thinktin-production-canary-<版本>.yaml`。
4. 灰度有问题：直接 `kubectl delete -f thinktin-production-canary-<版本>.yaml`。灰度副本手里的运行停机时交回，
   别的副本接着跑；电脑重连到老副本。迁移不用退（规则 3 保证老版本照常跑）。

滚动更新一次换一个副本（`maxSurge 1`、`maxUnavailable 0`）：新副本就绪才停老的。停机时控制面先报未就绪 5 秒
让负载均衡摘掉，再等进行中的请求最多 30 秒，后台副本马上交回手里的运行（[常驻可靠性演练](reliability-drill.md)
测过滚动发版）；中继让电脑重连到别的副本；模型网关收到 SIGTERM 后再接 5 秒新连接，然后等进行中的流式响应
最多 4 分钟、用量都落库再退出。

**客户端和灰度**：灰度期间同一个用户的请求可能落到新版本，也可能落到老版本。新接口要等全量以后客户端才能依赖；
用到新接口的 App 版本在服务端全量之后再提交审核。接口版本协商（`proto::api`）保证老 App 照常能用。

## 5. 配置和密钥

控制面的配置在 `deploy/k8s/overlays/<环境>/server.toml`（ConfigMap `thinktin-server`，接口副本和后台副本共用），
标了“部署前填”的是占位值，按实际的云资源改；改完 `cargo test -p server deployment_configs_are_valid`
（CI 也跑）确认这一版能解析、按两种角色都通过校验。模型网关和中继要的公钥在 overlay 的 ConfigMap 里
（不是密钥）：沙箱令牌的公钥（`llm-gw keygen` 生成密钥时打印）、访问令牌的公钥（`thinktin-server check-config` 打印）。

密钥由运维在每个命名空间里建 Secret（键就是环境变量名）。签名种子、验证码密钥、数据库密码和对应的公钥用
`thinktin-server gen-secrets` 生成（每个环境一套）：

| Secret | 键 | 给谁 |
|---|---|---|
| `thinktin-api` | `DATABASE_URL`（控制面登录账号）、`THINKTIN_ACCESS_TOKEN_SEED`、`THINKTIN_CODE_PEPPER`、`THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID`、`THINKTIN_ALIYUN_KMS_ACCESS_KEY_SECRET`（本地 KMS 时换成 `THINKTIN_KMS_KEY`）、`THINKTIN_S3_ACCESS_KEY_ID`、`THINKTIN_S3_SECRET_ACCESS_KEY`、`THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID`、`THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET`；提交审核期间加 `THINKTIN_REVIEW_CODE` | 接口副本 |
| `thinktin-worker` | `DATABASE_URL`（控制面登录账号）、`THINKTIN_SANDBOX_TOKEN_SEED`、KMS 的两个（同上）、对象存储的两个、`THINKTIN_CUBE_API_KEY`、`THINKTIN_JPUSH_MASTER_SECRET` | 后台副本 |
| `thinktin-push`（文件） | `apns.p8`（APNs 私钥）、`fcm.json`（FCM 服务账号） | 后台副本，挂在 `/etc/thinktin/push` |
| `thinktin-llm-gw` | `DATABASE_URL`（模型网关登录账号）、KMS 的两个 | 模型网关 |
| `thinktin-relay` | `DATABASE_URL`（中继登录账号） | 设备中继 |
| `thinktin-migrate` | `DATABASE_URL`（表的属主） | 迁移 Job |

**应用商店审核账号（4.7）**：审核员收不到短信。提交审核前在 `server.toml` 的 `[api]` 里配 `review_phone`（一个
不会有人用的手机号），在 `thinktin-api` 里加 `THINKTIN_REVIEW_CODE`（6 位数字，不能是同一个数字或连号）。这个号发码
时不发短信，码就是这个固定码；限频、有效期、尝试次数和普通的码一样，发码（`auth.review_code`）和登录（`auth.login`
的 `review: true`）都记审计，启动时打一条警告。手机号和码填在 App Store Connect 的审核备注里。审核过了就把两个都删掉、
重新部署（只配一个启动不了）。

接口副本和后台副本拿到的密钥不一样：接口副本没有沙箱令牌私钥、CubeAPI 和推送的密钥，后台副本没有访问令牌私钥、
验证码密钥和短信的密钥。换密钥：访问令牌、沙箱令牌的公钥都可以同时给新旧两个（中继的 `THINKTIN_ACCESS_TOKEN_KEYS`
用逗号分隔；模型网关多加一个 `--token-key`），先发公钥、再换私钥、旧令牌过期后去掉旧公钥。

## 6. 回滚

- **程序**：`kubectl apply -f thinktin-production-<上一版>.yaml`（上一版 GitHub Release 的附件）。上一版程序在新的表结构上
  照常跑，启动时看到数据库比它新只记一条日志。
- **迁移不回滚**：没有反向迁移。迁移本身有问题就写一个新迁移修（往前修），走正常的发布。
- **灰度阶段**：删掉灰度副本即可，见第 4 节。

## 7. 入口和还没做的

- 对外 HTTPS：客户端接口（`thinktin-api`）和电脑连中继的 wss（`thinktin-relay`）由云负载均衡或 Ingress 终止 TLS，
  要支持 WebSocket、空闲超时大于中继的心跳（20 秒）。沙箱访问模型网关走内网负载均衡（Cube 节点在集群外，
  `server.toml` 的 `sandbox.gateway_url`）；模型网关不对公网。这部分随 2.2、2.3 按云厂商配。
- 还没做：自动扩缩（17.5 压测后按结果配）、NetworkPolicy（随 2.7 出网策略）、灰度指标的自动判断
  （现在人看指标决定全量还是放弃）。

# 服务机上的部署（东京 10 人测试环境）

把平台的四个服务（接口 `thinktin-api`、后台 `thinktin-worker`、模型网关 `thinktin-llm-gw`、设备中继 `thinktin-relay`）部署到
阿里云东京的服务机 `thinktin-svc` 上。背景和取舍见 [阿里云部署计划](../../../docs/deploy-aliyun-sg.md) 第 1、8.9 节，
通用的清单见 [部署环境准备清单](../../../docs/deploy-checklist.md)；这份只讲在这台机器上怎么做。

服务机不开 22，只用云助手操作：脚本用 `deploy/aliyun/run.sh ecs --push` 传上去，再用 `--run` 在机器上执行。
**不要用 `--run-file` 跑 03–06**：它们要同目录的 `common.sh`，06 也超过了云助手一条命令 18 KB 的上限。

```
App / 电脑 ──https / wss──▶ Caddy（服务机，80 / 443，Let's Encrypt 证书）
                              ├─ api.thinktin.si   → Service thinktin-api   10.43.0.80:80
                              └─ relay.thinktin.si → Service thinktin-relay 10.43.0.81:80
                            k3s 单机（命名空间 thinktin）
                              thinktin-api、thinktin-worker、thinktin-relay   各 1 个 Pod
                              thinktin-llm-gw   用服务机的网络，172.16.0.168:8790（模型）、8791（受控出网）◀── ACS 里的沙箱
                            PostgreSQL 16（服务机上，数据盘）   Pod 经 172.16.0.168:5432 连
                            Caddy 172.16.0.168:7788 ──▶ sandbox-manager（ACS 里的 Pod，地址写在一个文件里）
```

## 1. 脚本

| 脚本 | 做什么 | 多久 |
|---|---|---|
| `01-disk-postgres.sh`、`02-build-images.sh` | 数据盘和 PostgreSQL 16；从源码构建三个服务镜像（2026-11-10 做过了） | — |
| `03-k3s-caddy.sh` | 装 k3s（钉死版本，单机，不装 traefik / servicelb / local-storage）、镜像从 docker 导进 k3s、装 Caddy 写 Caddyfile、等两个域名的证书 | 后台，3–6 分钟 |
| `04-database.sh` | 生成平台密钥（只一次）、建库 `thinktin` 和 10 个角色、放开 Pod 网段来连、每个账号连一遍 | 十几秒 |
| `05-secrets.sh` | 本地主密钥、审核账号的固定码（各只生成一次）；建命名空间、5 个 Secret、2 个公钥 ConfigMap | 几秒 |
| `06-deploy.sh` | 生成部署包、跑迁移 Job、起四个服务、体检。`--status` 只体检，`--review-check` 实测审核账号发码 | 后台，1–3 分钟 |
| `sandbox-upstream.sh` | 看、探、换 sandbox-manager 的上游 | 几秒 |
| `common.sh` | 上面几个共用的常量（地址、网段、镜像版本）和函数，不单独跑 | — |

每个脚本都可以重跑：已经有的东西不重装、不重建，密钥和密码不重新生成，数据不动。

## 2. 第一次部署：在云端会话里按这个顺序跑

都在仓库根目录执行。传上去的是**本地工作区**现在的样子，所以先 `git pull` 到要部署的提交。

```sh
# 0. 脚本和清单（以后仓库里改了 deploy/aliyun 或 deploy/k8s，重传对应的那个再跑后面的步骤）
deploy/aliyun/run.sh ecs --push deploy/aliyun /opt/thinktin/deploy/aliyun
deploy/aliyun/run.sh ecs --push deploy/k8s /opt/thinktin/deploy/k8s

# 1. k3s、镜像、Caddy、证书（后台跑；隔一会儿看一次日志，等最后一行 K3S-CADDY OK）
deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/03-k3s-caddy.sh'
deploy/aliyun/run.sh ecs --run 'tail -40 /opt/thinktin/k3s-caddy.log'

# 2. 数据库
deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/04-database.sh'

# 3. OSS 的访问密钥（建好只管这个桶的 RAM 子账号以后；文件怎么写见第 6 节）。要在第 2 步之后传：密钥目录那时已经建好、收紧了
deploy/aliyun/run.sh ecs --push target/thinktin-secrets/oss.env /opt/thinktin/secrets/oss.env

# 4. Secret 和公钥
deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/05-secrets.sh'

# 5. 迁移、起服务、体检（后台跑；等最后一行 DEPLOY OK）
deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/06-deploy.sh'
deploy/aliyun/run.sh ecs --run 'tail -70 /opt/thinktin/deploy.log'

# 6. 验收：体检（随时可以再跑）、从外面连公网入口、审核账号发码
deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/06-deploy.sh --status'
curl -sS https://api.thinktin.si/version
deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/06-deploy.sh --review-check'
```

镜像版本默认是 `0.1.0-tokyo.b1309ba`（`common.sh` 的 `VERSION`）。部署别的版本时，03、06 都带上同一个，比如
`--run 'VERSION=0.1.0-tokyo.abc1234 bash /opt/thinktin/deploy/aliyun/machine/06-deploy.sh'`。

### 每一步成功是什么样

- **03**：马上回一行“在后台开始了”。日志里依次是 `[通过] 节点 thinktin-svc Ready …`、三行 `[已导] thinktin.local/tokyo/…`、
  `[通过] 三个镜像 kubelet 都看得到`、`[通过] Caddy … 在监听 80、443、172.16.0.168:7788`、两行 `[通过] … 的证书签下来了`，
  最后 `K3S-CADDY OK`。这时接口还没部署，`https://api.thinktin.si` 回 502 是正常的。
- **04**：`[已生成] 平台密钥 …（不显示）`、`[通过] 库 thinktin（属主 thinktin_owner）；thinktin_ 开头的角色 10 个`、角色表、
  `[已重启] Postgres 现在监听 localhost,172.16.0.168`、四行登录检查的 `[通过]`。
- **05**：`[已生成] 本地主密钥 …`、`[已生成] 审核账号的固定码 …`，然后 7 行 `[created] secret/…` / `configmap/…`，每行后面只列键名。
  没有 `oss.env` 时在这里停下，说缺哪个文件。
- **06**：马上回一行“前提都在；部署在后台开始了”。日志里 `[已生成] …/tokyo-migrate.yaml、…/tokyo.yaml`、
  `[通过] 迁移跑完了：… migrations applied`、四行 `[通过] thinktin-… 换好了`、体检（下一条），最后 `DEPLOY OK`。
- **体检**（`--status`）：四个 Deployment 就绪、镜像是要的版本；接口经 Service 和经 Caddy 的 `/healthz`、`/readyz`、`/version`；
  中继的 `/readyz`、`/healthz`、wss 握手（不带令牌答 401）；服务机在监听 8790、8791；从后台副本的 Pod 里经 7788 问
  sandbox-manager（答 404：连得上、Key 也认）；审核账号配没配；最近的 ERROR 条数、内存、磁盘。没过的标 `[不通过]`，
  最后一行是 `体检全过。` 或者没过几项。“经公网”那一条是从服务机绕出去再回来，不通只标 `[注意]`，以外面 `curl` 的结果为准。

输出里没有密钥：密钥只显示“有没有”、文件名和权限。

## 3. 重跑、换版本、改配置

- **哪一步失败了**：看它打印的原因，修好以后重跑同一步。03、06 在后台跑的时候再跑一次会说“上一次还在跑”。
- **改了 `server.toml` 或清单**：先 `cargo test -p server deployment_configs_are_valid`，提交，然后
  `--push deploy/k8s …`，再跑 06。只有配置变了的服务会重启（接口和后台共用 `server.toml`，一起重启）。
- **加了或换了密钥文件**（`oss.env`、`sms.env`、`search.env`、`review.code`）：跑 05，再跑 06。06 只重启用到这个 Secret 的服务。
- **换程序版本**：云端会话里把新提交的源码传上去、`VERSION=… 02-build-images.sh` 构建（见该脚本头上的说明），然后带同一个
  `VERSION` 跑 03（只做导镜像这一件新事）和 06（新版本的迁移 Job 先跑，再换程序）。
- **回滚程序**：带上一版的 `VERSION` 跑 06（上一版的镜像一般还在 k3s 里；06 说没有的话，带那个 `VERSION` 先跑一次 03 导回来）。
  迁移不回滚，上一版程序在新的表结构上照常跑（[发布流程](../../../docs/release.md) 第 3、6 节）。
- **迁移失败**：服务不动。看 06 打印的 Job 日志，修好以后重跑 06，它会删掉失败的 Job 再跑。

## 4. 停掉、拆掉，各自留下什么

```sh
# 只停服务，什么都不删（之后跑 06 恢复：副本数回到 1）
deploy/aliyun/run.sh ecs --run '/usr/local/bin/k3s kubectl -n thinktin scale deploy --all --replicas=0'
# 把平台从 k3s 里整个拿掉（模型网关有进行中的请求时最多等 5 分钟才删完）
deploy/aliyun/run.sh ecs --run '/usr/local/bin/k3s kubectl delete namespace thinktin --wait=false'
```

删掉命名空间以后：

- **没了的**：四个服务、Service、迁移 Job、Secret 和 ConfigMap（都能从服务机上的文件原样建回来）。
- **还在的**：Postgres 里的库和账号（所有用户数据）；`/opt/thinktin/secrets`（全部密钥）；OSS 桶里的产出物和工作区归档；
  k3s 和导进去的镜像；Caddy 和证书（入口回 502）；sandbox-manager 的上游文件。
- **还在收钱的**：ACS 里已经建出来的沙箱。后台副本停了就没人去暂停、归档它们：要停很久的话，在服务机上用 ACS 的 kubectl
  看一眼（`/opt/thinktin/target/bin/kubectl --kubeconfig /opt/thinktin/target/aliyun-acs/kubeconfig get sandboxes -A`），不要的删掉。
- **恢复**：跑 05、再跑 06。密钥还是原来那一套，用户的登录状态、存的 key、归档都还能用。

更彻底的（都要用户明确同意）：`/usr/local/bin/k3s-uninstall.sh` 卸掉 k3s（Postgres、密钥文件、Caddy 不动；重装从 03 开始）；
删库 `runuser -u postgres -- dropdb thinktin` **丢掉所有用户数据**，之后要删掉旧的迁移 Job、从 04 重做。
`/opt/thinktin/secrets` 任何时候都不要删：`kms.key` 没了，库里用户存的 key、OSS 里的东西都解不开。

## 5. 换 sandbox-manager 的上游

sandbox-manager 是 ACS 集群里的一个 Pod，现在直接连它的 Pod IP（`172.29.47.90:7788`），Pod 重建以后 IP 会变。
`server.toml` 里写的是服务机上的入口 `http://172.16.0.168:7788/kruise/api`，Caddy 转给上游；上游**只写在
`/opt/thinktin/sandbox-manager.upstream` 这一个文件**里（`to <IP>:<端口>` 那一行），变了只改它，平台的服务不用重启。

```sh
# 看现在的上游，经 Caddy 探一下
deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/sandbox-upstream.sh'
# 换成新地址（先直接探新地址，通了才改；改完重载 Caddy 再探）
deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/sandbox-upstream.sh 172.29.47.91:7788'
# 不知道新地址：让脚本去 ACS 集群里查（服务机上的 kubeconfig 是短时的，过期了先重取重传）
deploy/aliyun/run.sh acs --fetch-kubeconfig
deploy/aliyun/run.sh ecs --push target/aliyun-acs /opt/thinktin/target/aliyun-acs
deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/sandbox-upstream.sh --discover'
```

症状：体检里“后台副本到 sandbox-manager”那一条是 `Caddy 答了 502`，App 里新建 botin、发消息一直失败。
重载 Caddy 会断开已经连着的中继 wss 和事件流，客户端会自己重连。以后给 sandbox-manager 配了固定入口（内网负载均衡），
把 `server.toml` 的 `api_url` 换成它，这个转发就不用了。

## 6. 密钥：在哪、怎么来、怎么备份

都在服务机的 `/opt/thinktin/secrets`（目录 `0700`、文件 `0600`，只有 root 读得到），不进仓库、不进聊天、不进日志：

| 文件 | 内容 | 怎么来 |
|---|---|---|
| `gen-secrets.txt` | 访问令牌、沙箱令牌的签名种子，验证码密钥，四个数据库密码，两个公钥 | 04 用服务镜像跑 `gen-secrets`，只一次 |
| `kms.key` | 本地主密钥 `THINKTIN_KMS_KEY` | 05 生成，只一次。**要备份** |
| `review.code` | 审核账号的固定验证码 | 05 生成，只一次；想自己定就先放一个 6 位数字的文件 |
| `oss.env` | `THINKTIN_S3_ACCESS_KEY_ID=…`、`THINKTIN_S3_SECRET_ACCESS_KEY=…` 两行 | 云端会话建子账号以后传上来 |
| `sms.env`（可选） | `THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID=…`、`THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET=…` | 短信批下来以后放 |
| `search.env`（可选） | `THINKTIN_PARALLEL_SEARCH_KEY`、`THINKTIN_DEEPSEEK_SEARCH_KEY`、`THINKTIN_IQS_API_KEY`，有哪个写哪个 | 有了搜索的 key 以后放 |

- **`oss.env` 怎么写**：一行一个 `键=值`，不加引号、不留空格。在云端会话里写到 `target/thinktin-secrets/oss.env`
  （`target/` 不进仓库、也不进 autosave 快照；先 `umask 077`），程序直接把接口返回的 Key 写进文件，不要打印出来。
  用 `--push` 传的内容会留在阿里云云助手的命令记录里（Base64 的压缩包，能调 ECS 接口的账号看得到）：这把 Key 只管一个桶，
  介意的话以后在 RAM 里轮换一次、由用户在控制台里自己写文件。
- sandbox-manager 的 Key 不在这个目录：05 从 `/opt/thinktin/target/aliyun-acs/sandbox.json` 读（装组件时生成、传上来的）。
- **备份**：`kms.key` 丢了无法恢复（用户存的 key、产出物、工作区归档全部解不开）。`gen-secrets.txt` 丢了可以重新生成，代价是
  四个数据库密码要重设（`SYNC_PASSWORDS=1` 跑 04）、发出去的访问令牌和沙箱令牌全部作废一次。备份由用户在阿里云控制台里对这台
  机器用云助手或 Workbench 读出来，存进密码管理器；不经过聊天。
- 两个公钥（不是密钥）：ConfigMap `thinktin-llm-gw`、`thinktin-relay` 由 05 直接建进集群，值来自 `gen-secrets.txt`。
  仓库里的 `overlays/tokyo` 不含这两个 ConfigMap，所以重新 apply 不会把它们冲掉，也没有要回填、要提交的东西。

## 7. 测试的人怎么登录（短信批下来之前）

短信的签名和模板还在审核，短信的 Key 在 Secret 里是占位值：普通手机号点“获取验证码”会失败。这期间用**审核账号**登录
（[发布流程](../../../docs/release.md) 第 5 节）：

1. App 的接口地址要指到 `https://api.thinktin.si`（iOS 的 `THINKTIN_API_BASE_URL`、安卓的 `BASE_URL`），电脑的中继地址
   `wss://relay.thinktin.si`。
2. 登录页区号选 **+86**，手机号填 **120 0000 2026**（`server.toml` 的 `review_phone = "+8612000002026"`；12 开头不是真实号段）。
3. 点“获取验证码”（不会有短信），验证码填服务机上 `/opt/thinktin/secrets/review.code` 里的 **6 位数字**。这个码由用户在阿里云
   控制台 → ECS → 这台机器 → 云助手里执行 `cat /opt/thinktin/secrets/review.code` 自己看，再发给测试的人；不在聊天里显示。
4. 要知道的限制：所有用这个号登录的人是**同一个账号**（同一批 botin 和数据，各自一台设备）；这个号一天最多要 10 次码、
   两次之间隔 60 秒，码 5 分钟内有效、输错 5 次作废重新要；登录以后靠刷新令牌保持，平时不用重新登录。

短信通了以后：`server.toml` 的 `[sms.aliyun]` 换成真的签名和模板、删掉 `review_phone`，服务机上放 `sms.env`，
跑 05（它会把固定码从 Secret 里去掉）和 06。`review_phone` 和固定码只留一个接口副本起不来。

## 8. 几个做法和原因

- **Caddy 转给 Service 的固定 ClusterIP，不用 NodePort**：k3s 的服务机自己连得上集群内地址（kube-proxy 的规则对本机发出的
  连接也生效）；`10.43.0.80`、`10.43.0.81` 在服务网段里留给手动指定的那一段，写死在清单和 Caddyfile 两边，删了命名空间重建也不变。
  NodePort 会在服务机所有地址上多开两个端口（包括公网那一面，只能靠安全组挡），还多一层端口映射。
  接口看到的对端是服务机自己，所以 `server.toml` 开了 `trust_forwarded_for`，限频按 Caddy 追加的来源地址算。
- **模型网关用服务机的网络**（`hostNetwork`）：沙箱令牌绑定沙箱的 Pod IP，网关要直接看到来源地址，前面不能有会换地址的东西。
  所以它不能新旧两个 Pod 同时在，换版本时先停旧的（`Recreate`）。
- **Postgres**：只多监听 `172.16.0.168`；`pg_hba.conf` 只放行 k3s 的 Pod 网段 `10.42.0.0/16` 和服务机自己的 `172.16.0.168/32`
  （模型网关用服务机的网络，从这个地址连过来），只许连库 `thinktin`、只许四个登录账号、`scram-sha-256`。5432 不在安全组里。
  角色和 [准备清单](../../../docs/deploy-checklist.md) 第 3 节一模一样；项目成员的两个角色（8.15）也建了：跨用户项目虽然关着，
  迁移 0049 和控制面启动时的角色核对都要它们在。
- **镜像不经过仓库**：`docker save | k3s ctr images import`，清单里 `imagePullPolicy: Never`（迁移 Job 也是）。
- **配置指纹**：`envFrom` 的 Secret、挂载的 `server.toml` 变了 Pod 不会自己重启。06 把每个 Deployment 用到的配置文件和
  Secret / ConfigMap 的版本算成一个摘要，写进 Pod 模板的注解 `thinktin.si/config-stamp`：变了才滚动重启，没变的不动。
- **不发短信也能起来**：接口副本没有短信配置起不来（`api.dev_sms` 只许本地开发，配置校验测试也不让部署配置开它），所以
  `[sms.aliyun]` 填了占位的签名和模板、Secret 里填占位的 Key：程序能启动，普通号码发码时阿里云拒绝，审核账号不走短信。
- **关着的**：跨用户项目（`[api] cross_user_projects` 默认关）、项目派单（库里的开关默认关，不要跑 `admin project-dispatch on`）、
  推送（没配 `[push.*]`）、平台搜索（没有 key 时 agent 没有 `web_search`）。

## 9. 一台 2 核 4G 够不够

基础清单是按多副本的集群写的，`overlays/tokyo` 已经改掉的：每个服务 1 个副本；PodDisruptionBudget 的 `minAvailable` 改成 0
（单副本留着 1 的话节点永远排不空）；探针超时放宽到 5 秒 / 3 秒（默认 1 秒，2 核上被别的活挤一下就误判）；模型网关 `Recreate`；
镜像只用本地的。基础清单里没有反亲和、拓扑分布这类单机满足不了的约束。

- **请求量**：四个服务合计 CPU 850m、内存 896Mi，加上 k3s 自己的 coredns、metrics-server 约 200m / 140Mi；滚动更新时每个服务多起一个
  新 Pod，最多再加 600m。2 核装得下，但发布时会比较挤（所以放宽了探针）。
- **内存上限**：三个 1Gi 加一个 512Mi，合起来超过了机器能给的（k3s 自己约 0.6–0.9G，Postgres、Caddy、docker 另算）。平时每个服务
  只用几十到一两百 MB；真要同时顶到上限，机器会先用交换空间变慢。测试阶段没改上限，体检里会打印内存。
- **磁盘**：后台副本的 `/tmp` 是 10Gi 的临时卷（存放工作区归档时用），在 40G 的系统盘上；docker 的镜像和构建缓存也在系统盘。
  系统盘用到 85% 时 kubelet 开始清没在用的镜像，只剩 5% 时开始赶 Pod：03 和体检都会打印用量，到 75% 就提醒；
  紧了用 `docker builder prune -af` 腾出构建缓存（下次构建要从头编，约半小时）。
- **重启**：k3s、Caddy、Postgres 都是开机自启；Postgres 加了等网卡就绪再启动（它要绑内网地址）。

## 10. 真用户进来之前还缺的

- **短信**：签名、验证码模板、只管短信的子账号 Key（第 7 节最后一段）。现在只有审核账号能登录。
- **agent 模板镜像和 SandboxSet**：5 种 agent 的模板镜像推进东京的 ACR，每个模板版本建一个 SandboxSet（名字按
  [ACS 后端](../../../docs/sandbox-acs.md) 第 2 节的规则，或者在 `[sandbox.acs.templates]` 里映射），**模板要带
  `network.alibabacloud.com/vswitch-ids`、`network.alibabacloud.com/security-group-ids` 两个注解**（沙箱自己的交换机和安全组，
  ID 在 `target/aliyun-acs/network.json`），不然沙箱之间互通。没有这些，能登录，但 botin 的沙箱建不出来，发消息、跑任务都会失败。
- **OSS**：只管这个桶的子账号和 Key（第 2 节第 3 步）；S3 兼容接口的签名区域（`oss-ap-northeast-1`）还没实测，第一次存产出物或
  归档工作区时看后台副本的日志。
- **推送**：APNs 的 `.p8`（Secret `thinktin-push`、`[push.apns]`）、安卓的极光或 FCM。没有时任务结果、审批只能开着 App 看。
- **搜索的 key**：`search.env`。
- **sandbox-manager 的固定入口**（现在靠第 5 节手动换）、**服务机的公网地址换成 EIP**（现在是买机器时自动分的，释放机器就没了，
  换了要改 DNS 和 `--egress-deny`）。
- **备份和监控**：Postgres 的定时备份（现在没有）、`kms.key` 的备份、磁盘和内存的告警、灰度和回滚演练。
- 合规、隐私政策、App 的上架材料见部署计划第 7 节。

## 11. 排错

```sh
K='/usr/local/bin/k3s kubectl -n thinktin'
deploy/aliyun/run.sh ecs --run "$K get pods -o wide; $K get events --sort-by=.lastTimestamp | tail -15"
deploy/aliyun/run.sh ecs --run "$K logs deploy/thinktin-api --tail=50 | cut -c1-300"
deploy/aliyun/run.sh ecs --run 'journalctl -u caddy -n 40 --no-pager | cut -c1-300'
deploy/aliyun/run.sh ecs --run 'journalctl -u k3s -n 40 --no-pager | cut -c1-300'
```

- Pod 一直 `ErrImageNeverPull`：这个版本的镜像没导进 k3s，带同一个 `VERSION` 跑 03。
- Pod 反复重启，日志说 `checking the database migrations`：迁移没跑或者库比程序旧，看迁移 Job；说
  `checking the database roles`：重跑 04。
- 接口副本日志说 `api.review_phone needs THINKTIN_REVIEW_CODE` 或者反过来：`server.toml` 和 Secret 没对上，传最新的
  `deploy/k8s`、跑 05 再跑 06。
- 证书签不下来：公网要查得到两个域名指向 `8.216.52.81`，安全组要放行 80、443；看 `journalctl -u caddy`。
- 服务机上的 `kubectl` 是 k3s 的（连这台机器上的 k3s）；ACS 集群要用 `/opt/thinktin/target/bin/kubectl --kubeconfig …`，别混。
- 云助手一次最多返回约 24 KB 输出：长日志用 `tail`、`cut -c1-300` 截一下。

# agent 的沙箱模板（WBS 6.8）

每个内置 agent 一个模板镜像：agent-shim + 这个 agent（版本写死）+ 它要的运行时。沙箱从模板建出来，
实例锁在领养时的版本上（6.7）。模板按 [CubeSandbox 的模板约定](sandbox-cube.md#2-模板约定68-构建模板时照这个做) 构建。

## 1. 装什么：清单的 `[install]`

要装的包写在清单（`crates/catalog/manifests/<id>.toml`）里，版本都写死：

```toml
[install]
npm = ["@agentclientprotocol/claude-agent-acp@0.90.0"]   # 全局安装，命令在 /usr/local/bin
pip = ["hermes-agent[acp,mcp]==0.19.0"]                  # 装进 /opt/agents/<id> 这个虚拟环境，bin 在 PATH 上
```

清单校验（`catalog` 的测试守住）：每个包都锁定确切的版本（不能是范围、`latest`）；`agent.version` 是其中一个包的版本；
`runtime.template` 是 `agents/<id>:<agent.version>`。所以升级 agent 时这三处一起改，漏改测试就不过。

只锁了直接装的包，它们的依赖在构建时解析：同一个清单隔一段时间重建，依赖可能不一样。所以模板构建好以后
**按镜像摘要用**，每次重建都重新冒烟。

## 2. 镜像

`deploy/templates/Dockerfile`，用 `deploy/templates/build.sh <id>` 构建（它从清单里读模板名、版本和包）：

- 基础镜像 `node:24-trixie-slim`（OpenClaw 要 Node 24.16 以上），加 Python 3、git、ripgrep、jq、curl 这些 agent
  常用的命令行工具，不装编译器。
- 用户 `user`（不用 root），HOME 是 `/sandbox/home`，工作区 `/sandbox/workspace`（Cube 的卷挂在这里）。
- agent-shim 在 `/usr/local/bin`。默认在镜像里从源码编译；给 `SHIM_DIR`（里面是 `out/agent-shim`）就直接用编好的。
- 镜像名是 `<前缀>/<runtime.template>`，前缀默认 `thinktin`，比如 `thinktin/agents/claude:0.90.0`。

```sh
deploy/templates/build.sh claude                       # 构建
deploy/templates/smoke.sh thinktin/agents/claude:0.90.0 claude   # 冒烟
```

现在五个模板（解压后的大小）：Pi 508 MB、Hermes 587 MB、Claude 695 MB、Codex 852 MB、OpenClaw 905 MB。

## 3. 冒烟：断网跑一轮

`deploy/templates/smoke.sh <镜像> <id>` 在 `--network none` 的容器里起模型网关的替身（`tools/mock-llm`），
经镜像里的 agent-shim 让 agent 跑一轮（`tools/smoke/smoke.sh`），检查 agent 就绪、这一轮结束、回复对、
每个模型请求都带沙箱令牌。断网同时证明 agent 只要模型网关就能干活，不偷偷连外网（自部署、遥测和自更新关掉了）。
五个 agent 都通过（2026-10-17）；Hermes 会先不带凭证探测一串本地推理服务的接口（`/api/tags`、`/props` 之类），
真实的模型网关一律回 401，不影响。每次的结果写成流水线的注解（agent 的版本、回复、模型请求、各项检查）。

## 4. 流水线（`.github/workflows/templates.yml`）

- 改了清单、agent-shim、模板、冒烟脚本或许可证策略，推到 `main`、`backend-core` 时：主机上编一次 agent-shim，
  五个 agent 逐个构建、冒烟，再按许可证策略检查镜像里的第三方组件（[第三方许可证](licenses.md)），不推送。
- 打 `v*` 标签（和服务端一起发布）时：构建、冒烟通过后推到镜像仓库（前缀同服务端镜像，见[发布流程](release.md)）：
  `agents/<id>:<agent 版本>`，另打一个 `agents/<id>:<agent 版本>-<平台版本>`（模板里的 agent-shim 是这个平台版本的，
  平台版本之间 shim 协议有变化时据此区分）。镜像摘要写在运行的摘要页里。
- 每周一看一次上游（`deploy/templates/upstream.py`）：每个锁定的包对照 npm、PyPI 上的最新版本，有新的写成提醒。

## 5. 上架一个新版本

1. 看上游的发布说明和许可证有没有变（每周的上游检查会报许可证变化，[第三方许可证](licenses.md) 第 5 节），新版本有没有
   新的联网行为、配置项要关（[加固基线](agent-hardening.md)）。`deploy/templates/notices/<id>/` 里补的上游原文是按旧版本
   核对的，要按那里 `sources.toml` 的说明重新核对、改版本号（不改 CI 会报错）。
2. 旧清单移到 `crates/catalog/manifests/archive/<id>-<旧版本>.toml`、登记进 `ARCHIVED`（锁在旧版本上的实例照常跑、
   能回滚）；改新清单的 `agent.version`、`runtime.template`、`[install]`。
3. 推上去，CI 和模板流水线都绿（清单校验、shim 测试、断网冒烟）。
4. 打标签发布：模板镜像推到仓库；在 Cube 里从镜像建模板（2.3 以后）：

   ```sh
   cubemastercli tpl create-from-image --image <镜像>@<摘要> \
     --writable-layer-size <大小> --cpu <毫核> --memory <MB> --expose-port 49983 --probe 49983
   ```

   CPU、内存按清单的 `runtime.vcpu`、`runtime.memory_mb`。控制面按清单的 `runtime.template` 找模板，
   Cube 里的模板名（或别名）要和它对上。
5. 发布控制面（带新清单）：新领养的实例用新版本；已有的实例在用户或平台升级时重建（6.7）。

## 6. 还没做的

- **envd**：Cube 从镜像建模板时镜像里要有 envd（探活端口 49983）。来源（Cube 提供的基础镜像，或从 E2B 的源码编译）
  和 Cube 模板名的对应方式等 2.3 部署集群时确定；到时换 `BASE_IMAGE` 或在 base 阶段加一层。
- **Codex 的模型目录**：Codex 不认识平台的模型别名，每轮开头提醒一句；要在模板构建时从 Codex 本身取系统提示词，
  生成 `model_catalog_json`（[接入说明](agent-integration.md) 第 8 节）。
- **OpenClaw 的人设文件**（AGENTS.md、SOUL.md 等）放进模板，不在用户的工作区里生成。
- 依赖的完整锁定（每个 agent 一份 lockfile）、arm64 镜像。

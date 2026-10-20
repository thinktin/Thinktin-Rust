# syntax=docker/dockerfile:1
#
# agent 的沙箱模板（WBS 6.8）：agent-shim + 一个 agent + 它要的运行时（Node 24、Python 3），
# 按 docs/sandbox-cube.md 第 2 节的模板约定。要装的包和版本来自清单 crates/catalog/manifests/<id>.toml
# 的 [install]，用 deploy/templates/build.sh 构建（它读清单、传参数）。说明见 docs/templates.md。
# 构建上下文是仓库根目录，只带 Dockerfile.dockerignore 放行的文件。
#
# Cube 从镜像建模板时要求镜像里有 envd（探活端口 49983）。envd 的来源（Cube 提供的基础镜像，或者从 E2B 的
# 源码编译）等 2.3 部署集群时确定：换 BASE_IMAGE，或者在 base 阶段加一层。

ARG RUST_IMAGE=rust:1-trixie
ARG BASE_IMAGE=node:24-trixie-slim

# agent-shim 默认从源码编译。CI 先在主机上编好，用 `--build-context shim=<目录>` 直接给
# （目录里放 out/agent-shim），这个阶段就跳过了。
FROM ${RUST_IMAGE} AS shim
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/target,sharing=locked \
    cargo build --release --locked -p agent-shim \
    && mkdir -p /out \
    && cp target/release/agent-shim /out/

FROM ${BASE_IMAGE} AS base
ENV LANG=C.UTF-8
# agent 干活常用的命令行工具。不装编译器：要编译的 Python 包装不上，构建时就会发现。
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates curl git jq less procps python3 python3-venv ripgrep unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*
# 根目录 /sandbox：HOME 是 /sandbox/home，工作区是 /sandbox/workspace（Cube 的卷挂在这里），
# 进程以 user 运行（不用 root）。
RUN useradd --create-home --home-dir /sandbox/home --shell /bin/bash --uid 1001 user \
    && mkdir -p /sandbox/workspace \
    && chown user:user /sandbox/workspace
COPY --from=shim /out/agent-shim /usr/local/bin/agent-shim

FROM base AS agent
ARG AGENT_ID
ARG AGENT_VERSION
ARG NPM_PACKAGES=""
ARG PIP_PACKAGES=""
# npm 包装到全局（命令在 /usr/local/bin），Python 包装到 agent 自己的虚拟环境 /opt/agents/<id>。
RUN set -f; if [ -n "$NPM_PACKAGES" ]; then \
        npm install --global --no-fund --no-audit --no-update-notifier $NPM_PACKAGES \
        && npm cache clean --force; \
    fi
RUN set -f; if [ -n "$PIP_PACKAGES" ]; then \
        python3 -m venv "/opt/agents/$AGENT_ID" \
        && "/opt/agents/$AGENT_ID/bin/pip" install --no-cache-dir $PIP_PACKAGES; \
    fi
# 第三方许可清单（16.5）：每个包的许可证、NOTICE 原文和清单，放在 /usr/share/doc/thinktin-agent。
COPY deploy/templates/licenses.py deploy/templates/license-policy.toml /usr/local/lib/thinktin/
RUN python3 /usr/local/lib/thinktin/licenses.py --agent "$AGENT_ID" \
        --policy /usr/local/lib/thinktin/license-policy.toml
ENV PATH=/opt/agents/${AGENT_ID}/bin:${PATH} \
    HOME=/sandbox/home
LABEL io.thinktin.agent=${AGENT_ID} \
      io.thinktin.agent-version=${AGENT_VERSION}
USER user
WORKDIR /sandbox/workspace
ENTRYPOINT []
CMD ["agent-shim", "--help"]

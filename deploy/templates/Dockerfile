# syntax=docker/dockerfile:1
#
# agent 的沙箱模板（WBS 6.8）：agent-shim + 一个 agent + 它要的运行时（Node 24、Python 3），
# 按 docs/sandbox-cube.md 第 2 节的模板约定。要装的包和版本来自清单 crates/catalog/manifests/<id>.toml
# 的 [install]，用 deploy/templates/build.sh 构建（它读清单、传参数）。说明见 docs/templates.md。
#
# Cube 从镜像建模板时要求镜像里有 envd（探活端口 49983）。envd 的来源（Cube 提供的基础镜像，或者从 E2B 的
# 源码编译）等 2.3 部署集群时确定：换 BASE_IMAGE，或者在 base 阶段加一层。

ARG RUST_IMAGE=rust:1-trixie
ARG BASE_IMAGE=node:24-trixie-slim

# agent-shim 默认从源码编译，同时生成它依赖的 crate 的许可证清单（16.5）。CI 先在主机上编好，
# 用 `--build-context shim=<目录>` 直接给（目录里放 out/agent-shim 和 out/licenses），这个阶段就跳过了。
FROM ${RUST_IMAGE} AS shim
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/target,sharing=locked \
    cargo build --release --locked -p agent-shim \
    && mkdir -p /out \
    && cp target/release/agent-shim /out/ \
    && python3 tools/licenses/licenses.py cargo -p agent-shim --subject agent-shim \
        --target "$(rustc -vV | sed -n 's/^host: //p')" --out /out/licenses

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
# 第三方许可证（16.5，docs/licenses.md）：镜像里所有 npm、Python、Debian 包和 agent-shim 的 crate，
# 原文复制到 /usr/share/thinktin/licenses，清单 inventory.json 由 CI 按许可证策略检查。
# 上游有、包里没带的原文（比如 Codex 的 NOTICE）放在 deploy/templates/notices/<agent id>/。
COPY tools/licenses /tmp/licenses/tool
COPY crates/catalog/manifests/${AGENT_ID}.toml /tmp/licenses/manifest.toml
COPY deploy/templates/notices /tmp/licenses/notices
COPY --from=shim /out/licenses /tmp/licenses/shim
RUN set -f; extra="--extra /tmp/licenses/notices/_base"; \
    [ ! -d "/tmp/licenses/notices/$AGENT_ID" ] || extra="$extra --extra /tmp/licenses/notices/$AGENT_ID"; \
    python3 /tmp/licenses/tool/licenses.py scan --out /usr/share/thinktin/licenses \
        --subject "agents/$AGENT_ID:$AGENT_VERSION" --manifest /tmp/licenses/manifest.toml \
        --npm-root /usr/local/lib/node_modules --site-packages "/opt/agents/$AGENT_ID/lib/python3*/site-packages" \
        --deb --node $extra --merge /tmp/licenses/shim \
    && rm -rf /tmp/licenses
ENV PATH=/opt/agents/${AGENT_ID}/bin:${PATH} \
    HOME=/sandbox/home
LABEL io.thinktin.agent=${AGENT_ID} \
      io.thinktin.agent-version=${AGENT_VERSION}
USER user
WORKDIR /sandbox/workspace
ENTRYPOINT []
CMD ["agent-shim", "--help"]

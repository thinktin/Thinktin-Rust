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
# 清单 [install] prune：装好以后删掉的东西（许可证审查不过、agent 又用不到的，比如商用字体）。
# npm:<install.npm 里某个包下的路径> 或 pip:<site-packages 下的路径>，每项至少要匹配到一个，不然是上游改了目录，要重新看。
# 和安装在同一层里删：分开的话，删掉的文件还留在安装那一层里，镜像照样带着。
ARG PRUNE=""
# npm 包装到全局（命令在 /usr/local/bin），Python 包装到 agent 自己的虚拟环境 /opt/agents/<id>。
RUN set -f; if [ -n "$NPM_PACKAGES" ]; then \
        npm install --global --no-fund --no-audit --no-update-notifier $NPM_PACKAGES \
        && npm cache clean --force || exit 1; \
    fi; \
    if [ -n "$PIP_PACKAGES" ]; then \
        python3 -m venv "/opt/agents/$AGENT_ID" \
        && "/opt/agents/$AGENT_ID/bin/pip" install --no-cache-dir $PIP_PACKAGES || exit 1; \
    fi; \
    for spec in $PRUNE; do \
        case "$spec" in \
            npm:*) base=/usr/local/lib/node_modules ;; \
            pip:*) set +f; set -- /opt/agents/$AGENT_ID/lib/python3*/site-packages; set -f; base="$1" ;; \
            *) echo "install.prune: $spec 要以 npm: 或 pip: 开头" >&2; exit 1 ;; \
        esac; \
        set +f; set -- $base/${spec#*:}; set -f; \
        if [ ! -e "$1" ]; then echo "install.prune: $spec 一个也没匹配到（上游改了目录？）" >&2; exit 1; fi; \
        rm -rf -- "$@" || exit 1; \
    done
# 清单 [install.bin]：包没放上 PATH、接入方式要直接调用的程序，链接到 /usr/local/bin（比如 Claude 的 `claude`）。
# 每项是 <命令名>=<全局 npm 目录下的路径>，路径里的通配符必须正好匹配一个可执行文件；已经有同名命令时失败，不覆盖。
ARG NPM_BINS=""
RUN set -f; for pair in $NPM_BINS; do \
        name="${pair%%=*}"; pattern="${pair#*=}"; \
        set +f; set -- /usr/local/lib/node_modules/$pattern; set -f; \
        if [ "$#" -ne 1 ] || [ ! -x "$1" ]; then \
            echo "install.bin.$name: $pattern 要正好匹配一个可执行文件，匹配到：$*" >&2; exit 1; \
        fi; \
        ln -s "$1" "/usr/local/bin/$name" || exit 1; \
    done
# agent 的浏览器（docs/browser.md 第 2.4、2.6 节）：只在 WITH_BROWSER=1 时装（清单写了 [browser] supported，或者
# Phase 0 的测试镜像，见 build.sh）。Chromium 用 Debian 的包，不锁死小版本（安全更新一出旧版本就从源里下掉了），每 1–2 周
# 重建一次；装上的版本写进 /opt/thinktin/browser/chromium-version，许可证清单里也有。/usr/bin/chromium 移出 PATH：Hermes
# 见到它会自己挂浏览器工具（不经守门），shim 直接执行 /usr/lib/chromium/chromium。托管策略属 root、0644，agent 改不了。
# Playwright MCP 装在 /opt/thinktin/browser（不在 PATH 上），不下载它自己的浏览器；打补丁去掉 CDP 模式下的 bind()
# （没正好命中一处就失败），生成 tools.json（shim 一开始列给 agent 的工具）。
ARG WITH_BROWSER=0
COPY deploy/templates/browser /tmp/browser
RUN if [ "$WITH_BROWSER" = 1 ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            chromium fonts-noto-cjk fonts-noto-color-emoji \
        && rm -rf /var/lib/apt/lists/* \
        && test -x /usr/lib/chromium/chromium \
        && dpkg-divert --local --rename --divert /usr/lib/chromium/chromium-wrapper --add /usr/bin/chromium \
        && ! command -v chromium \
        && mkdir -p /etc/chromium/policies/managed \
        && install -m 0644 /tmp/browser/chromium-policy.json /etc/chromium/policies/managed/thinktin.json \
        && mkdir -p /opt/thinktin/browser \
        && cp /tmp/browser/launch.cjs /tmp/browser/patch-playwright.cjs /tmp/browser/list-tools.cjs /opt/thinktin/browser/ \
        && cd /opt/thinktin/browser \
        && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-fund --no-audit --no-update-notifier @playwright/mcp@0.0.84 \
        && npm cache clean --force \
        && node patch-playwright.cjs node_modules \
        && node list-tools.cjs > tools.json \
        && agent-shim check-browser-tools tools.json \
        && dpkg-query -W -f='${Version}\n' chromium > chromium-version \
        && test ! -e /root/.cache/ms-playwright || exit 1; \
    fi; \
    rm -rf /tmp/browser
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
        --npm-root /usr/local/lib/node_modules --npm-package "/opt/yarn-*" \
        $( [ -d /opt/thinktin/browser/node_modules ] && echo --npm-root /opt/thinktin/browser/node_modules ) \
        --site-packages "/opt/agents/$AGENT_ID/lib/python3*/site-packages" \
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

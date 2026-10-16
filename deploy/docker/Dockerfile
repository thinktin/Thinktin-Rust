# syntax=docker/dockerfile:1
#
# 服务端镜像（WBS 2.9）：控制面、模型网关、设备中继三个程序一次编译，按目标出三个镜像。
# 在仓库根目录构建：
#
#   docker build -f deploy/docker/Dockerfile --target server -t thinktin-server .
#   docker build -f deploy/docker/Dockerfile --target llm-gw -t thinktin-llm-gw .
#   docker build -f deploy/docker/Dockerfile --target relay  -t thinktin-relay  .
#
# 运行时镜像只有 glibc、CA 证书和程序本身（没有 shell、包管理器），以 nonroot（uid 65532）运行。
# 配置和密钥都从环境变量、挂载的文件来，镜像里不放任何密钥。发布流程见 docs/release.md。

ARG RUST_IMAGE=rust:1-trixie
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian13:nonroot

FROM ${RUST_IMAGE} AS build
WORKDIR /src
COPY . .
# 发布构建由流水线按标签传版本（`/version`、启动日志、thinktin_build_info 指标里看得到）。
ARG THINKTIN_VERSION
ENV THINKTIN_VERSION=${THINKTIN_VERSION}
# --locked：用提交的 Cargo.lock，依赖和 CI 测过的一样。
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/target,sharing=locked \
    cargo build --release --locked -p server -p llm-gw -p relay \
    && mkdir -p /out \
    && cp target/release/thinktin-server target/release/llm-gw target/release/thinktin-relay /out/

# 控制面：接入网关（客户端接口）和后台任务（调度、执行、推送）同一个程序，按配置开哪一部分。
FROM ${RUNTIME_IMAGE} AS server
COPY --from=build /out/thinktin-server /usr/local/bin/thinktin-server
ENV THINKTIN_LISTEN=0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/thinktin-server"]
CMD ["serve"]

# 模型网关：用户 key 的明文只在这里出现，单独部署（参数见 `llm-gw serve --help`）。
FROM ${RUNTIME_IMAGE} AS llm-gw
COPY --from=build /out/llm-gw /usr/local/bin/llm-gw
EXPOSE 8790
ENTRYPOINT ["/usr/local/bin/llm-gw"]
CMD ["serve", "--listen", "0.0.0.0:8790", "--log-json"]

# 设备中继：电脑的长连接（参数见 `thinktin-relay --help`）。
FROM ${RUNTIME_IMAGE} AS relay
COPY --from=build /out/thinktin-relay /usr/local/bin/thinktin-relay
ENV THINKTIN_RELAY_LISTEN=0.0.0.0:8792
EXPOSE 8792
ENTRYPOINT ["/usr/local/bin/thinktin-relay"]

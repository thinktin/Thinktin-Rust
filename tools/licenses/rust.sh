#!/usr/bin/env bash
# 发出去的每个 Rust 程序依赖的 crate：生成许可证清单，按策略检查（WBS 16.5，docs/licenses.md）。CI 每次都跑。
#
#   tools/licenses/rust.sh [输出目录，默认 target/licenses]
#
# 不限平台：算的是所有平台上可能编进去的依赖（比只算一个平台多，不会漏）。镜像里带的清单只算镜像的平台。
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:-target/licenses}"
py=tools/licenses/licenses.py
status=0

check() {  # 名字 包...
  local name=$1
  shift
  local args=()
  for p in "$@"; do args+=(-p "$p"); done
  python3 "$py" cargo --subject "$name" --out "$out/$name" "${args[@]}"
  python3 "$py" check "$out/$name/inventory.json" || status=1
}

check server server llm-gw relay # 服务端镜像（deploy/docker/Dockerfile）
check agent-shim agent-shim      # 每个 agent 的模板镜像（deploy/templates）
check client-core client-core    # iOS、Android App 里的客户端核心
check desktop desktop            # macOS App 里的电脑端工具服务
exit $status

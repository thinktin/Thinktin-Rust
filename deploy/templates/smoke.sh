#!/usr/bin/env bash
# 模板镜像的冒烟测试（WBS 6.8）：在断网的容器里起模型网关替身（tools/mock-llm），经镜像里的 agent-shim
# 跑 agent 一轮，检查 agent 就绪、回复对、每个模型请求都带沙箱令牌（tools/smoke/smoke.sh）。
# 断网（--network none）同时证明 agent 不需要外网：自部署、只连模型网关。
#
# 用法：deploy/templates/smoke.sh <镜像> <agent id> [agent-shim run 的其他参数...]
#   SMOKE_TIMEOUT  最多等多少秒，默认 600
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
image=${1:?usage: smoke.sh <image> <agent id> [agent-shim args...]}
agent=${2:?usage: smoke.sh <image> <agent id> [agent-shim args...]}
shift 2
exec timeout "${SMOKE_TIMEOUT:-600}" docker run --rm --network none \
  -v "$root/tools:/tools:ro" -e SHIM=agent-shim \
  --entrypoint bash "$image" /tools/smoke/smoke.sh "$agent" "$@"

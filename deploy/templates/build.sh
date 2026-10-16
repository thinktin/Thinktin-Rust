#!/usr/bin/env bash
# 构建一个 agent 的沙箱模板镜像（WBS 6.8）：按清单 crates/catalog/manifests/<id>.toml 的 [install] 装包，
# 镜像名是 <前缀>/<清单的 runtime.template>（比如 thinktin/agents/claude:0.90.0）。说明见 docs/templates.md。
#
# 用法：deploy/templates/build.sh <agent id> [docker buildx build 的其他参数...]
#   IMAGE_PREFIX  镜像前缀，默认 thinktin
#   SHIM_DIR      编好的 agent-shim 所在的目录（里面是 out/agent-shim）；不给就在镜像里从源码编译
# 最后一行输出镜像名。
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
agent=${1:?usage: build.sh <agent id> [docker buildx build args...]}
shift
manifest="$root/crates/catalog/manifests/$agent.toml"
[ -f "$manifest" ] || { echo "no manifest $manifest" >&2; exit 2; }

# 从清单里取模板名、版本和要装的包（Python 3.11 以上自带 tomllib）。
eval "$(python3 - "$manifest" <<'PY'
import shlex, sys, tomllib
m = tomllib.load(open(sys.argv[1], "rb"))
inst = m.get("install", {})
for key, value in [
    ("template", m["runtime"]["template"]),
    ("version", m["agent"]["version"]),
    ("npm", " ".join(inst.get("npm", []))),
    ("pip", " ".join(inst.get("pip", []))),
]:
    print(f"{key}={shlex.quote(value)}")
PY
)"
[ -n "$npm$pip" ] || { echo "$manifest has no [install]" >&2; exit 2; }

image="${IMAGE_PREFIX:-thinktin}/$template"
args=(
  -f "$root/deploy/templates/Dockerfile"
  --build-arg "AGENT_ID=$agent"
  --build-arg "AGENT_VERSION=$version"
  --build-arg "NPM_PACKAGES=$npm"
  --build-arg "PIP_PACKAGES=$pip"
  -t "$image"
)
if [ -n "${SHIM_DIR:-}" ]; then
  args+=(--build-context "shim=$SHIM_DIR")
fi
docker buildx build "${args[@]}" "$@" "$root" >&2
echo "$image"

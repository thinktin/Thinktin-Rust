# shellcheck shell=bash
# 服务机上第三到第六步（03–06、sandbox-upstream.sh）共用的常量和函数：由它们 source，不单独执行。
# 说明和执行顺序见同目录的 README.md。
#
# 密钥的规矩（每个脚本都守）：值只放在 /opt/thinktin/secrets（目录 0700、文件 0600）和 k3s 的 Secret 里；不 echo、
# 不进日志、不出现在命令行参数里（ps 看得到），要交给别的程序时走标准输入或只有 root 能读的临时文件。不开 set -x。
set +x
# 云助手给的 PATH 不一定有 /usr/local/bin（k3s 装在那里）和 sbin。
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

ROOT=/opt/thinktin
SECRETS=$ROOT/secrets
RENDER=$ROOT/render
GEN_FILE=$SECRETS/gen-secrets.txt
ACS_STATE=$ROOT/target/aliyun-acs/sandbox.json
OVERLAY=$ROOT/deploy/k8s/overlays/tokyo

# 服务机（deploy/aliyun/ecs.py 建的 thinktin-svc）。和 deploy/k8s/overlays/tokyo 里写的是同一组值。
NODE_IP=172.16.0.168
PUBLIC_IP=8.216.52.81
API_HOST=api.thinktin.si
RELAY_HOST=relay.thinktin.si

# k3s 的网段（默认值，03 写进 /etc/rancher/k3s/config.yaml）。Postgres 按 Pod 网段放行，Caddy 按固定的 Service 地址转发。
POD_CIDR=10.42.0.0/16
SERVICE_CIDR=10.43.0.0/16
API_SERVICE_IP=10.43.0.80
RELAY_SERVICE_IP=10.43.0.81
NAMESPACE=thinktin

# 服务镜像（02-build-images.sh 构建的）。换版本时每一步都带同一个 VERSION=…。
IMAGE_PREFIX=${PREFIX:-thinktin.local/tokyo}
VERSION=${VERSION:-0.1.0-tokyo.b1309ba}

DB_NAME=thinktin
DB_PORT=5432
# 数据库账号（crates/server/src/secrets.rs 的 DB_LOGINS）：迁移用属主，三个服务各用自己的登录账号。
DB_LOGINS="thinktin_owner thinktin_server_login thinktin_llmgw_login thinktin_relay_login"

# sandbox-manager：Caddy 在 NODE_IP:7788 转给上游，上游只写在这一个文件里（sandbox-upstream.sh 改它）。
SANDBOX_PROXY_PORT=7788
UPSTREAM_FILE=$ROOT/sandbox-manager.upstream
DEFAULT_UPSTREAM=172.29.47.90:7788

die() {
  echo "[不通过] $*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" = 0 ] || die "要用 root 跑（云助手默认就是）"
}

# k3s 自带的 kubectl，连的是这台机器上的 k3s（/etc/rancher/k3s/k3s.yaml）。不要和 target/bin/kubectl 混用：那个配的是 ACS 集群。
K3S=/usr/local/bin/k3s
k() {
  "$K3S" kubectl "$@"
}

k3s_ready() {
  [ -x "$K3S" ] && k get --raw /readyz >/dev/null 2>&1
}

# 一个服务正在跑的 Pod 的主进程号（在它的网络命名空间里探路用）：pod_pid thinktin-worker。没有就输出空。
pod_pid() {
  local cid pid
  cid=$(k -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=$1" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].status.containerStatuses[0].containerID}' 2>/dev/null) || return 0
  cid=${cid#containerd://}
  [ -n "$cid" ] || return 0
  pid=$("$K3S" crictl inspect -o go-template --template '{{.info.pid}}' "$cid" 2>/dev/null || true)
  if ! [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    pid=$("$K3S" crictl inspect "$cid" 2>/dev/null | sed -n 's/^ *"pid": *\([0-9][0-9]*\).*$/\1/p' | head -n 1 || true)
  fi
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "$pid"
  fi
}

# 镜像全名：image server|llm-gw|relay
image() {
  echo "$IMAGE_PREFIX/thinktin-$1:$VERSION"
}

# 等一个条件成立：wait_for <秒数> <说明> <命令…>
wait_for() {
  local secs=$1 what=$2 end
  shift 2
  end=$((SECONDS + secs))
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$end" ]; then
      echo "[不通过] 等了 ${secs} 秒还没好：$what"
      return 1
    fi
    sleep 3
  done
}

secrets_dir() {
  mkdir -p "$SECRETS"
  chown root:root "$SECRETS"
  chmod 700 "$SECRETS"
}

# gen-secrets 输出里 “键=值” 那几行的值（THINKTIN_ACCESS_TOKEN_SEED、THINKTIN_CODE_PEPPER、THINKTIN_SANDBOX_TOKEN_SEED）。
gen_value() {
  sed -n "/^$1=/{s/^$1=//p;q}" "$GEN_FILE"
}

# 数据库登录账号的密码（“账号: 密码” 那几行）。
db_password() {
  sed -n "/^$1: /{s/^$1: //p;q}" "$GEN_FILE"
}

# 公钥（不是秘密）：public_key relay → a1=…（THINKTIN_ACCESS_TOKEN_KEYS），public_key llm-gw → k1=…（THINKTIN_SANDBOX_TOKEN_KEY）。
public_key() {
  case "$1" in
    relay) sed -n '/^thinktin-relay  *THINKTIN_ACCESS_TOKEN_KEYS=/{s/^thinktin-relay  *THINKTIN_ACCESS_TOKEN_KEYS=//p;q}' "$GEN_FILE" ;;
    llm-gw) sed -n '/^thinktin-llm-gw  *THINKTIN_SANDBOX_TOKEN_KEY=/{s/^thinktin-llm-gw  *THINKTIN_SANDBOX_TOKEN_KEY=//p;q}' "$GEN_FILE" ;;
  esac
}

# gen-secrets 的输出齐不齐、样子对不对（只看格式，不显示值）。
gen_file_ok() {
  local v login
  for v in THINKTIN_ACCESS_TOKEN_SEED THINKTIN_SANDBOX_TOKEN_SEED; do
    [[ "$(gen_value "$v")" =~ ^[A-Za-z0-9_-]{32,}$ ]] || return 1
  done
  [[ "$(gen_value THINKTIN_CODE_PEPPER)" =~ ^[0-9a-f]{64}$ ]] || return 1
  for login in $DB_LOGINS; do
    [[ "$(db_password "$login")" =~ ^[A-Za-z0-9_-]{24,}$ ]] || return 1
  done
  [[ "$(public_key relay)" =~ ^[A-Za-z0-9_-]+=[A-Za-z0-9_-]{40,}$ ]] || return 1
  [[ "$(public_key llm-gw)" =~ ^[A-Za-z0-9_-]+=[A-Za-z0-9_-]{40,}$ ]] || return 1
}

# 只生成一次：两个签名种子、验证码密钥、四个数据库密码和两个公钥（thinktin-server gen-secrets，
# docs/deploy-checklist.md 第 3 节）。已经有就不动——重新生成等于换掉所有密码和签名密钥。
gen_secrets_once() {
  secrets_dir
  if [ -s "$GEN_FILE" ]; then
    chmod 600 "$GEN_FILE"
    gen_file_ok || die "$GEN_FILE 的内容不完整（不显示）。不要直接删：库里的密码、发出去的令牌都跟着它。先弄清楚怎么回事"
    return 0
  fi
  command -v docker >/dev/null || die "没有 docker：gen-secrets 要用服务镜像跑（02-build-images.sh 装的）"
  local ref tmp
  ref=$(image server)
  docker image inspect "$ref" >/dev/null 2>&1 || die "docker 里没有 $ref：先跑 02-build-images.sh，或者带上对的 VERSION=…"
  tmp=$(mktemp "$SECRETS/.gen-secrets.XXXXXX")
  # kid 和 server.toml 的 api.access_token_kid、sandbox.token_kid 一致（05 会核对）。不用网络、不写盘。
  if ! docker run --rm --network none --read-only "$ref" gen-secrets --access-kid a1 --sandbox-kid k1 > "$tmp" 2> "$tmp.err"; then
    head -n 5 "$tmp.err" >&2
    rm -f "$tmp" "$tmp.err"
    die "gen-secrets 没跑成"
  fi
  rm -f "$tmp.err"
  if ! GEN_FILE=$tmp gen_file_ok; then
    rm -f "$tmp"
    die "gen-secrets 的输出和预期的格式不一样（程序改过输出？对照 crates/server/src/secrets.rs 的 render）"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$GEN_FILE"
  echo "[已生成] 平台密钥 $GEN_FILE（只有 root 能读，不显示；只生成这一次）"
}

# “键=值” 文件里一个键的值（oss.env、sms.env、search.env）。
env_file_value() {
  sed -n "/^$2=/{s/^$2=//p;q}" "$1" | tr -d '\r'
}

# sandbox-manager 现在的上游（UPSTREAM_FILE 里 “to <地址>” 那一行）。
upstream_now() {
  sed -n '/^[[:space:]]*to[[:space:]]/{s/^[[:space:]]*to[[:space:]][[:space:]]*\([^[:space:]]*\).*$/\1/p;q}' "$UPSTREAM_FILE" 2>/dev/null
}

# 把上游写进 UPSTREAM_FILE（Caddyfile 里 import 它）。只有这一个地方写着 sandbox-manager 的地址。
write_upstream() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5}$ ]] || die "上游要写成 IP:端口，比如 $DEFAULT_UPSTREAM"
  cat > "$UPSTREAM_FILE" <<EOF
# sandbox-manager 现在的地址：Caddy 的 $NODE_IP:$SANDBOX_PROXY_PORT 转到这里（/etc/caddy/Caddyfile 里 import 这个文件）。
# 它是 ACS 集群里的一个 Pod，重建以后 IP 会变。换地址：
#   bash $ROOT/deploy/aliyun/machine/sandbox-upstream.sh <IP>:<端口>     （检查、重载 Caddy、再探一下）
# 手改的话只改下面这一行 to 后面的地址，然后 systemctl reload caddy。
to $1
EOF
  chmod 644 "$UPSTREAM_FILE"
}

# 问 sandbox-manager 一个不存在的沙箱（只读），输出 HTTP 状态码：
#   404 通，Key 也认；401 / 403 通，Key 不认；502 Caddy 连不上上游（Pod IP 变了）；000 连不上；nokey 读不出 Key。
# sandbox_manager_code [进程号] [地址:端口]
#   进程号：在那个进程的网络命名空间里问（后台副本的 Pod：和它自己发请求走同一条路）；空着就从服务机问。
#   地址：默认经 Caddy 的 NODE_IP:7788（和 server.toml 的 api_url 同一个入口）；换上游之前用它直接探新地址。
sandbox_manager_code() {
  local pid=${1:-} target=${2:-$NODE_IP:$SANDBOX_PROXY_PORT} cfg code
  cfg=$(mktemp /run/thinktin-curl.XXXXXX)
  # Key 写进只有 root 能读的临时文件给 curl（-K），不上命令行。
  if ! python3 - "$ACS_STATE" > "$cfg" 2>/dev/null <<'PY'
import json
import re
import sys

key = json.load(open(sys.argv[1]))["api_key"]
if not re.fullmatch(r"[A-Za-z0-9_.-]+", key):
    sys.exit(1)
print('header = "X-API-KEY: %s"' % key)
PY
  then
    rm -f "$cfg"
    echo nokey
    return 0
  fi
  set -- curl -s -o /dev/null -m 10 -w '%{http_code}' -K "$cfg" "http://$target/kruise/api/sandboxes/thinktin-health-probe"
  if [ -n "$pid" ]; then
    code=$(nsenter -t "$pid" -n "$@" 2>/dev/null) || true
  else
    code=$("$@" 2>/dev/null) || true
  fi
  rm -f "$cfg"
  echo "${code:-000}"
}

# 状态码是什么意思（给体检和 sandbox-upstream.sh 用）。通了返回 0。
sandbox_manager_verdict() {
  case "$1" in
    404 | 200)
      echo "[通过] sandbox-manager 答了 $1（连得上，Key 也认；问的是一个不存在的沙箱）"
      ;;
    401 | 403)
      echo "[不通过] sandbox-manager 答了 $1：连得上，但不认 $ACS_STATE 里的 Key"
      return 1
      ;;
    502 | 503 | 504)
      echo "[不通过] Caddy 答了 $1：连不上上游 $(upstream_now)（sandbox-manager 的 Pod IP 变了？见 README“换 sandbox-manager 的上游”）"
      return 1
      ;;
    000)
      echo "[不通过] 连不上 $NODE_IP:$SANDBOX_PROXY_PORT（Caddy 没起来，或者这条路不通）"
      return 1
      ;;
    nokey)
      echo "[不通过] 读不出 $ACS_STATE 里的 api_key（sandbox-manager 的 Key）"
      return 1
      ;;
    [1-4][0-9][0-9])
      echo "[注意] sandbox-manager 这条路答了 $1：连得上，但不是预期的 404（接口变了？）"
      ;;
    *)
      echo "[不通过] sandbox-manager 这条路答了 $1"
      return 1
      ;;
  esac
}

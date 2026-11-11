#!/usr/bin/env bash
# 服务机第三步（root，重跑没有副作用）：装 k3s（单机）、把三个服务镜像从 docker 导进 k3s、装 Caddy 并写好 Caddyfile。
# 先把脚本传上去，再在机器上跑（脚本之间有共用的 common.sh，所以不用 --run-file）：
#   deploy/aliyun/run.sh ecs --push deploy/aliyun /opt/thinktin/deploy/aliyun
#   deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/03-k3s-caddy.sh'
#
# 要下载 k3s、拉它的系统镜像、导三个镜像、等证书，一共几分钟：脚本把活放到后台就返回，日志在
# /opt/thinktin/k3s-caddy.log，结束时最后一行是 K3S-CADDY OK 或 K3S-CADDY FAILED。看进度：
#   deploy/aliyun/run.sh ecs --run 'tail -40 /opt/thinktin/k3s-caddy.log'
#
# 可以带的环境变量：VERSION=0.1.0-tokyo.<提交>（要导哪一版镜像，默认见 common.sh）、
# FORCE_IMPORT=1（同一个版本号的镜像重新构建过：k3s 里已经有也重新导一遍）、
# SANDBOX_MANAGER_UPSTREAM=<IP>:<端口>（第一次写上游文件时用；以后换上游用 sandbox-upstream.sh）。
#
# 定下来的做法：
# - k3s 钉死版本，二进制和安装脚本都核对 SHA-256；不装 traefik、servicelb（入口是服务机上的 Caddy）、local-storage（没有
#   用持久卷的服务）；kubeconfig 只有 root 能读。
# - 镜像不经过仓库：docker save | k3s ctr images import，清单里 imagePullPolicy 是 Never。
# - Caddy 用 Ubuntu 自带的包（2.6）。api / relay 两个域名的证书它自己向 Let's Encrypt 申请、续期，转给 k3s 里两个
#   固定地址的 Service（ClusterIP：k3s 的服务机自己连得上集群内地址，不用 NodePort 多开端口）；
#   另外在 172.16.0.168:7788 把 sandbox-manager 转给它现在的 Pod IP（上游只写在 /opt/thinktin/sandbox-manager.upstream）。
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=deploy/aliyun/machine/common.sh
. "$(dirname "$SELF")/common.sh"

# 和 ACS 集群（1.36）、机器上已有的 kubectl v1.36.5 同一个小版本。下面两个 SHA-256 是 2026-11-11 从发布页取的、核对过。
# （这几个变量故意不用 k3s 自己的前缀：安装脚本把环境里那个前缀开头的变量都当成给 k3s 的设置。）
PIN_VERSION="v1.36.6+k3s1"
# https://github.com/k3s-io/k3s/releases/download/v1.36.6%2Bk3s1/sha256sum-amd64.txt 里 k3s 那一行。
PIN_SHA256=66ceb8e67edfa547195135d74783bfadc2ecc04a91059e90ae5f70a3dbc98c15
# 同一个标签下的 install.sh（只用它建 systemd 服务、软链接和卸载脚本，二进制我们自己下、自己核对）。
PIN_INSTALL_SHA256=46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad
PIN_TAG=${PIN_VERSION/+/%2B}
BINARY_URL="https://github.com/k3s-io/k3s/releases/download/$PIN_TAG/k3s"
INSTALL_URL="https://raw.githubusercontent.com/k3s-io/k3s/$PIN_TAG/install.sh"
CONFIG=/etc/rancher/k3s/config.yaml
CADDYFILE=/etc/caddy/Caddyfile
LOG=$ROOT/k3s-caddy.log
LOCK=/run/thinktin-k3s-caddy.lock

if [ "${1:-}" != --foreground ]; then
  need_root
  for target in server llm-gw relay; do
    docker image inspect "$(image "$target")" >/dev/null 2>&1 \
      || die "docker 里没有 $(image "$target")：先跑 02-build-images.sh，或者带上对的 VERSION=…"
  done
  if ! (flock -n 9) 9> "$LOCK"; then
    die "上一次还在跑：tail -40 $LOG"
  fi
  nohup setsid bash "$SELF" --foreground > "$LOG" 2>&1 < /dev/null &
  echo "在后台开始了（k3s $PIN_VERSION，镜像 $VERSION）；日志 $LOG，最后一行是 K3S-CADDY OK 或 K3S-CADDY FAILED"
  exit 0
fi

exec 9> "$LOCK"
flock -n 9 || { echo "K3S-CADDY FAILED：另一个还在跑"; exit 1; }
DONE=0
finish() {
  local rc=$?
  rm -rf "${TMP:-}"
  if [ "$rc" = 0 ] && [ "$DONE" = 1 ]; then
    echo "K3S-CADDY OK $(date -u +%FT%TZ)"
  else
    echo "K3S-CADDY FAILED $(date -u +%FT%TZ)（退出码 $rc，原因在上面）"
  fi
}
trap finish EXIT
echo "K3S-CADDY START $(date -u +%FT%TZ)"
export DEBIAN_FRONTEND=noninteractive
TMP=$(mktemp -d)

# ---------- k3s ----------
echo "=== k3s"
k3s_config() {
  cat <<EOF
# ThinkTin 服务机的 k3s（deploy/aliyun/machine/03-k3s-caddy.sh 写的）。单机：服务端和节点是同一个进程。
write-kubeconfig-mode: "0600"
node-ip: $NODE_IP
# 网段是 k3s 的默认值，写出来是因为别处照着它配：Postgres 的 pg_hba 按 Pod 网段放行，Caddy 转给服务网段里两个固定地址。
# 建好集群以后不能改。
cluster-cidr: $POD_CIDR
service-cidr: $SERVICE_CIDR
disable:
  - traefik
  - servicelb
  - local-storage
EOF
}
mkdir -p "$(dirname "$CONFIG")"
if [ ! -f "$CONFIG" ]; then
  k3s_config > "$CONFIG"
  echo "[已写] $CONFIG"
elif [ "$(cat "$CONFIG")" != "$(k3s_config)" ]; then
  if [ -f /etc/systemd/system/k3s.service ]; then
    echo "[注意] $CONFIG 和脚本要写的不一样，k3s 已经装了：不动它（网段不能事后改）。要按脚本的来就先卸掉 k3s 重装。"
  else
    k3s_config > "$CONFIG"
    echo "[已改] $CONFIG"
  fi
fi

have=""
[ -x "$K3S" ] && have=$(sha256sum "$K3S" | cut -d' ' -f1)
if [ "$have" = "$PIN_SHA256" ]; then
  echo "[已有] $K3S 就是 $PIN_VERSION"
elif [ -n "$have" ]; then
  echo "[不通过] $K3S 是别的版本（$("$K3S" --version 2>/dev/null | head -n 1)）：这个脚本不做升级，先确认再手动处理"
  exit 1
else
  echo "下载 k3s $PIN_VERSION ……"
  curl -fsSL --retry 3 --retry-delay 3 -m 900 -o "$TMP/k3s" "$BINARY_URL"
  echo "$PIN_SHA256  $TMP/k3s" | sha256sum -c - >/dev/null || { echo "[不通过] 下载的 k3s 和钉死的 SHA-256 对不上"; exit 1; }
  install -m 0755 "$TMP/k3s" "$K3S"
  echo "[已装] $K3S（SHA-256 核对过）"
fi

if [ ! -f /etc/systemd/system/k3s.service ]; then
  curl -fsSL --retry 3 --retry-delay 3 -m 120 -o "$TMP/install.sh" "$INSTALL_URL"
  echo "$PIN_INSTALL_SHA256  $TMP/install.sh" | sha256sum -c - >/dev/null || { echo "[不通过] 下载的 install.sh 和钉死的 SHA-256 对不上"; exit 1; }
  # 二进制已经放好了（SKIP_DOWNLOAD）；参数都在 config.yaml 里。它会建服务、kubectl / crictl / ctr 软链接、卸载脚本，然后启动。
  # 环境清干净再跑，免得云助手的环境里碰巧有它认的变量被写进服务的配置。
  env -i PATH="$PATH" INSTALL_K3S_SKIP_DOWNLOAD=true sh "$TMP/install.sh" server 2>&1 | sed 's/^/  /'
fi
systemctl enable k3s >/dev/null 2>&1 || true
systemctl is-active -q k3s || systemctl start k3s

node_ready() {
  [ "$(k get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]
}
wait_for 300 "k3s 节点 Ready（journalctl -u k3s -n 50 看原因）" node_ready
# 系统镜像（coredns、metrics-server、pause）第一次要从 docker.io 拉。
wait_for 300 "coredns 建出来" k -n kube-system get deploy coredns
k -n kube-system rollout status deploy/coredns --timeout=300s >/dev/null \
  || { echo "[不通过] coredns 没起来（多半是系统镜像拉不下来）："; k -n kube-system get pods 2>&1 | cut -c1-120; exit 1; }
echo "[通过] 节点 $(k get nodes --no-headers 2>/dev/null | awk '{print $1, $2, $5}')；kubeconfig $(stat -c '%a %U' /etc/rancher/k3s/k3s.yaml)"

# ---------- 镜像 ----------
echo "=== 镜像导进 k3s"
for target in server llm-gw relay; do
  ref=$(image "$target")
  have=$("$K3S" ctr -n k8s.io images ls -q 2>/dev/null || true)
  if grep -qxF "$ref" <<< "$have" && [ "${FORCE_IMPORT:-}" != 1 ]; then
    echo "[已有] $ref"
    continue
  fi
  docker image inspect "$ref" >/dev/null 2>&1 || { echo "[不通过] docker 里没有 $ref"; exit 1; }
  docker save "$ref" | "$K3S" ctr -n k8s.io images import - >/dev/null
  have=$("$K3S" ctr -n k8s.io images ls -q 2>/dev/null || true)
  grep -qxF "$ref" <<< "$have" || { echo "[不通过] 导入以后 k3s 里找不到 $ref（k3s ctr -n k8s.io images ls 看实际的名字）"; exit 1; }
  echo "[已导] $ref"
done
# kubelet 看到的（清单里 imagePullPolicy 是 Never，名字和标签要一字不差）。
for target in server llm-gw relay; do
  "$K3S" crictl inspecti "$(image "$target")" >/dev/null 2>&1 || { echo "[不通过] crictl 找不到 $(image "$target")"; exit 1; }
done
echo "[通过] 三个镜像 kubelet 都看得到"

# ---------- Caddy ----------
echo "=== Caddy"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
  echo "[注意] ufw 开着：80、443 和 Pod 网段到本机的流量要放行（这台机器靠安全组挡外面，本来没开 ufw）"
fi
if ! command -v caddy >/dev/null; then
  # 系统的自动更新可能正占着 dpkg 的锁：等它，不马上失败。
  apt-get -o DPkg::Lock::Timeout=300 update -qq >/dev/null
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq caddy >/dev/null
  echo "[已装] $(caddy version | cut -d' ' -f1)"
fi
if [ -n "${SANDBOX_MANAGER_UPSTREAM:-}" ] && [ "$(upstream_now)" != "$SANDBOX_MANAGER_UPSTREAM" ]; then
  write_upstream "$SANDBOX_MANAGER_UPSTREAM"
elif [ -z "$(upstream_now)" ]; then
  write_upstream "$DEFAULT_UPSTREAM"
fi
runuser -u caddy -- test -r "$UPSTREAM_FILE" || { echo "[不通过] caddy 用户读不到 $UPSTREAM_FILE（看 $ROOT 的权限）"; exit 1; }

caddyfile() {
  cat <<EOF
# ThinkTin 服务机的入口（deploy/aliyun/machine/03-k3s-caddy.sh 写的：手改的内容下次跑脚本会被覆盖）。
{
	# 安全组只开了 TCP 的 80、443：不宣告 HTTP/3（UDP），免得客户端先去试一条不通的路。
	servers {
		protocols h1 h2
	}
}

# 客户端接口。证书自动向 Let's Encrypt 申请、续期；转给 k3s 里的 Service thinktin-api（地址固定，
# deploy/k8s/overlays/tokyo/kustomization.yaml）。事件流（SSE）来一点转一点；不记访问日志（路径里可能带 webhook 令牌）。
$API_HOST {
	reverse_proxy $API_SERVICE_IP:80 {
		flush_interval -1
	}
}

# 设备中继：电脑连上来的 wss。WebSocket 升级后的连接不受超时限制（中继每 20 秒有心跳）。
$RELAY_HOST {
	reverse_proxy $RELAY_SERVICE_IP:80 {
		flush_interval -1
	}
}

# sandbox-manager（ACS 集群里的 Pod，IP 会变）：只给这台机器和 k3s 的 Pod 用，上游只写在 $UPSTREAM_FILE。
# 控制面的一个请求可能等一分多钟（冷启动建沙箱），数据面是长时间的流和几个 G 的文件：不设响应超时、不攒着再转、
# 不重试、每个请求新建连接（上游换了地址以后不会还用着旧连接）。Host 换成上游自己的地址，和直连它时一样。
http://:$SANDBOX_PROXY_PORT {
	bind $NODE_IP
	@outside not remote_ip $POD_CIDR $NODE_IP/32 127.0.0.1/32
	respond @outside 403
	reverse_proxy {
		import $UPSTREAM_FILE
		header_up Host {http.reverse_proxy.upstream.hostport}
		flush_interval -1
		transport http {
			dial_timeout 5s
			keepalive off
		}
	}
}
EOF
}
if [ -f "$CADDYFILE" ] && [ ! -f "$CADDYFILE.dist" ] && ! grep -q "03-k3s-caddy.sh" "$CADDYFILE"; then
  cp -p "$CADDYFILE" "$CADDYFILE.dist"
fi
# 新文件先放在旁边校验（和服务同一个用户），过了才换上去；不过就留着原来的，Caddy 照旧跑。
caddyfile > "$CADDYFILE.new"
chmod 644 "$CADDYFILE.new"
if ! runuser -u caddy -- env HOME=/var/lib/caddy caddy validate --config "$CADDYFILE.new" --adapter caddyfile > "$TMP/validate.log" 2>&1; then
  echo "[不通过] 新的 Caddyfile 没通过校验（留在 $CADDYFILE.new，原来的没动）："
  { grep -v '"level":"info"' "$TMP/validate.log" || true; } | tail -n 5 | cut -c1-300
  exit 1
fi
if [ -f "$CADDYFILE" ] && cmp -s "$CADDYFILE.new" "$CADDYFILE"; then
  rm -f "$CADDYFILE.new"
  echo "[已有] $CADDYFILE 没变"
  changed=0
else
  mv "$CADDYFILE.new" "$CADDYFILE"
  echo "[已写] $CADDYFILE"
  changed=1
fi
systemctl enable caddy >/dev/null 2>&1 || true
if ! systemctl is-active -q caddy; then
  systemctl restart caddy
elif [ "$changed" = 1 ]; then
  # 重载会断开已经连着的长连接（中继的 wss、事件流），客户端会自己重连。
  systemctl reload caddy || { echo "[不通过] Caddy 重载失败："; journalctl -u caddy -n 8 --no-pager 2>/dev/null | cut -c1-300; exit 1; }
fi
listening() {
  local have
  have=$(ss -ltnH 2>/dev/null)
  grep -q ":443 " <<< "$have" && grep -q ":80 " <<< "$have" && grep -qF "$NODE_IP:$SANDBOX_PROXY_PORT " <<< "$have"
}
wait_for 30 "Caddy 监听 80、443 和 $NODE_IP:$SANDBOX_PROXY_PORT（journalctl -u caddy -n 30 看原因）" listening
echo "[通过] Caddy $(caddy version | cut -d' ' -f1) 在监听 80、443、$NODE_IP:$SANDBOX_PROXY_PORT；sandbox-manager 的上游是 $(upstream_now)"

# 证书：在本机用域名连自己（--resolve，不绕公网），TLS 握手过了就是证书签下来了。这时服务还没部署，接口回 502 是正常的。
cert_ok() {
  curl -sS -o /dev/null -m 5 --resolve "$1:443:127.0.0.1" "https://$1/healthz"
}
for host in "$API_HOST" "$RELAY_HOST"; do
  if wait_for 180 "$host 的证书" cert_ok "$host"; then
    expires=$(curl -sS -o /dev/null -m 5 -w '%{certs}' --resolve "$host:443:127.0.0.1" "https://$host/healthz" 2>/dev/null | sed -n '/[Ee]xpire [Dd]ate:/{s/^.*[Ee]xpire [Dd]ate: *//p;q}' || true)
    echo "[通过] $host 的证书签下来了${expires:+（到期 $expires）}"
  else
    echo "  公网要查得到 $host → $PUBLIC_IP，安全组要放行 80、443；Let's Encrypt 说了什么："
    journalctl -u caddy -n 200 --no-pager 2>/dev/null | grep -i -E "error|challenge failed|rate" | tail -n 4 | cut -c1-300 || true
    exit 1
  fi
done

echo "=== 现在的样子"
echo "k3s $("$K3S" --version | head -n 1 | cut -d' ' -f3)；$(k get nodes --no-headers 2>/dev/null | awk '{print "节点", $1, $2}')"
"$K3S" crictl images 2>/dev/null | awk -v p="$IMAGE_PREFIX/" 'index($1, p) == 1 {print "镜像", $1 ":" $2, $NF}'
free -m | awk '/^Mem/{print "  内存 " $3 " / " $2 " MB 在用"} /^Swap/{print "  交换 " $3 " / " $2 " MB 在用"}'
disk_note
DONE=1

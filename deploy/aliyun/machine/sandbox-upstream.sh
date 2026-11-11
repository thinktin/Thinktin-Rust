#!/usr/bin/env bash
# 看、换 sandbox-manager 的上游（root）。sandbox-manager 是 ACS 集群里的一个 Pod，重建以后 IP 会变；服务机上的 Caddy 在
# 172.16.0.168:7788 转给它（server.toml 的 [sandbox.acs] api_url 指的是这个入口，不用跟着改），上游只写在
# /opt/thinktin/sandbox-manager.upstream 这一个文件里。
#
#   deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/sandbox-upstream.sh'
#       看现在的上游，经 Caddy 探一下（只读）
#   deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/sandbox-upstream.sh 172.29.47.91:7788'
#       换成这个地址：先直接探它，通了才写文件、重载 Caddy，再经 Caddy 探一遍
#   deploy/aliyun/run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/machine/sandbox-upstream.sh --discover'
#       用 ACS 集群的 kubectl 查 sandbox-manager 现在的 Pod IP，和文件里的不一样就换。要服务机上的
#       /opt/thinktin/target/aliyun-acs/kubeconfig 没过期（它是短时的；过期了在云端会话里
#       deploy/aliyun/run.sh acs --fetch-kubeconfig，再 run.sh ecs --push target/aliyun-acs /opt/thinktin/target/aliyun-acs）
#
# FORCE=1：新地址探不通也换（sandbox-manager 正在重启、过一会儿才起来时）。
# 换上游不用重启平台的服务。重载 Caddy 会断开已经连着的长连接（中继的 wss、事件流），客户端自己重连。
set -euo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
# shellcheck source=deploy/aliyun/machine/common.sh
. "$(dirname "$SELF")/common.sh"
need_root

ACS_KUBECTL=$ROOT/target/bin/kubectl
ACS_KUBECONFIG=$ROOT/target/aliyun-acs/kubeconfig
# sandbox-manager 的服务端口（deploy/aliyun/sandbox.py 里也是它）。
MANAGER_PORT=7788

# 从 ACS 集群查 sandbox-manager 现在的地址（IP:端口）。
discover() {
  local pods ip
  [ -x "$ACS_KUBECTL" ] && [ -r "$ACS_KUBECONFIG" ] \
    || die "没有 $ACS_KUBECTL 或 $ACS_KUBECONFIG：在云端会话里 run.sh acs --fetch-kubeconfig，再把 target/aliyun-acs 传上来"
  pods=$("$ACS_KUBECTL" --kubeconfig "$ACS_KUBECONFIG" --request-timeout=20s get pods -n sandbox-system \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.status.podIP}{"\n"}{end}' 2>&1) \
    || die "问不到 ACS 集群（kubeconfig 过期了？它是短时的，重取重传）：$(tail -n 1 <<< "$pods" | cut -c1-200)"
  ip=$(awk '/^sandbox-manager/ && $2 == "Running" && $3 != "" {print $3; exit}' <<< "$pods")
  [ -n "$ip" ] || die "sandbox-system 里没有在跑的 sandbox-manager Pod：$(tr '\n' ';' <<< "$pods" | cut -c1-300)"
  echo "$ip:$MANAGER_PORT"
}

# 经 Caddy 探一遍：从服务机，后台副本在跑的话也从它的 Pod 里。
probe() {
  local pid ok=0
  echo "经 Caddy 的 $NODE_IP:$SANDBOX_PROXY_PORT（上游 $(upstream_now)），从服务机："
  sandbox_manager_verdict "$(sandbox_manager_code)" || ok=1
  if k3s_ready; then
    pid=$(pod_pid thinktin-worker)
    if [ -n "$pid" ]; then
      echo "从后台副本（thinktin-worker）的 Pod 里："
      sandbox_manager_verdict "$(sandbox_manager_code "$pid")" || ok=1
    fi
  fi
  return "$ok"
}

new=${1:-}
[ -f "$UPSTREAM_FILE" ] || die "没有 $UPSTREAM_FILE：先跑 03-k3s-caddy.sh"
old=$(upstream_now)
if [ -z "$new" ]; then
  echo "sandbox-manager 的上游现在是 ${old:-（文件里没有 to 那一行）}（$UPSTREAM_FILE）"
  probe
  exit
fi
if [ "$new" = --discover ]; then
  new=$(discover)
  echo "ACS 集群里 sandbox-manager 现在在 $new"
fi
[[ "$new" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5}$ ]] || die "上游要写成 IP:端口，比如 $DEFAULT_UPSTREAM"

if [ "$new" = "$old" ]; then
  echo "[已有] 上游已经是 $new，没改"
  probe
  exit
fi

# 先直接探新地址（不经 Caddy）：404 是通的、Key 也认。
code=$(sandbox_manager_code "" "$new")
case "$code" in
  404 | 200) echo "[通过] 直接连 $new：sandbox-manager 答了 $code" ;;
  *)
    if [ "${FORCE:-}" = 1 ]; then
      echo "[注意] 直接连 $new 答的是 $code，带了 FORCE=1，照样换"
    else
      die "直接连 $new 答的是 $code（应该是 404）：地址不对，或者 sandbox-manager 还没起来。没改。确定要换就带 FORCE=1"
    fi
    ;;
esac

backup=$(mktemp /run/thinktin-upstream.XXXXXX)
cp -p "$UPSTREAM_FILE" "$backup"
restore() {
  cp -p "$backup" "$UPSTREAM_FILE"
  rm -f "$backup"
}
write_upstream "$new"
if ! runuser -u caddy -- env HOME=/var/lib/caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  restore
  die "换了上游以后 Caddyfile 过不了校验，已经改回 $old（caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 看原因）"
fi
if ! systemctl reload caddy; then
  restore
  systemctl reload caddy || true
  die "Caddy 重载失败，已经改回 $old（journalctl -u caddy -n 20 看原因）"
fi
rm -f "$backup"
echo "[已换] sandbox-manager 的上游：${old:-（空）} → $new（$UPSTREAM_FILE），Caddy 重载了"
sleep 1
probe

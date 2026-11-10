#!/usr/bin/env bash
# 在服务机上跑（/opt/thinktin 下，`run.sh ecs --run 'bash /opt/thinktin/deploy/aliyun/probe-acs.sh'`）：用 Rust 的 AcsProvider
# （crates/sandbox/examples/acs_probe.rs 编出来的 bin/acs_probe）连真的 sandbox-manager。建预热池 → 临时在 8790 开个监听（看
# 沙箱连过来时的来源地址）→ 跑 acs_probe → 关监听、删预热池。sandbox-manager 直接连它的 Pod IP（同一个 VPC，不收费）。
set -uo pipefail
cd /opt/thinktin
K="target/bin/kubectl --kubeconfig target/aliyun-acs/kubeconfig"
chmod +x bin/acs_probe deploy/aliyun/run.sh

deploy/aliyun/run.sh acs --pool --offline --apply 2>&1 | tail -2

MANAGER=$($K get pods -n sandbox-system -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP}{"\n"}{end}' | awk '/^sandbox-manager/{print $2; exit}')
SELF=$(hostname -I | awk '{print $1}')
echo "sandbox-manager 的 Pod IP：$MANAGER；服务机内网地址：$SELF"

LOG=/opt/thinktin/gateway-probe.log
: > "$LOG"
python3 -m http.server 8790 --bind "$SELF" > "$LOG" 2>&1 &
LISTENER=$!
sleep 1

ACS_API_URL="http://$MANAGER:7788/kruise/api" \
ACS_API_KEY=$(python3 -c 'import json; print(json.load(open("target/aliyun-acs/sandbox.json"))["api_key"])') \
ACS_TEMPLATE=code-interpreter ACS_ROOT=/home/user ACS_GATEWAY="$SELF:8790" \
ACS_QUIET_SECS="${ACS_QUIET_SECS:-90}" ACS_IDLE_SECS="${ACS_IDLE_SECS:-330}" ACS_FILE_MB="${ACS_FILE_MB:-16}" \
  bin/acs_probe 2>&1 | sed -E 's/e2b_[0-9a-f]+/e2b_****/g'

kill "$LISTENER" 2>/dev/null
echo "--- 服务机上的监听看到的请求（来源地址在最前面）："
grep -E "probe-from|GET|code 404" "$LOG" | cut -c1-200 | head -5

deploy/aliyun/run.sh acs --pool-delete --offline --apply 2>&1 | tail -1
sleep 30
$K delete pods -n default -l agents.kruise.io/sandbox-pool=code-interpreter --wait=false >/dev/null 2>&1
sleep 15
echo "--- 还剩的沙箱："
$K get sandboxes,pods -n default 2>&1 | cut -c1-120

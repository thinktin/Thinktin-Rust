#!/usr/bin/env bash
# 真实 agent 冒烟测试：起本地模型网关替身（tools/mock-llm），用 agent-shim 跑一轮，
# 检查 agent 的回复、权限事件和网关日志（每个模型请求都必须带 shim 注入的沙箱令牌）。
#
# 用法：tools/smoke/smoke.sh <agent> [agent-shim run 的其他参数...]
#   PROMPT   提示词，默认 "Say hi"
#   EXPECT   回复里应包含的文字，默认 "pong from mock"
#   WORKDIR  放 HOME、工作目录和日志的目录，默认新建临时目录；复用同一目录可测会话接回
#   DUMP=1   把完整请求体存到 $WORKDIR/dump.jsonl
#   SHIM     agent-shim 路径，默认 target/debug/agent-shim
#   PORT     网关替身的端口，默认随机；有的 agent（如 Hermes）会把网关地址记进会话，测会话接回时要固定
#   EGRESS=1 用 strace 记录 agent 所有进程的 DNS 查询和网络连接，出现回环以外的连接就判失败
#            （需要 strace；会去掉代理变量，让外联直接暴露出来）。agent 都是自部署的，只应连模型网关
# agent 的可执行文件（claude-agent-acp、codex-acp、pi-acp、openclaw、hermes-acp）要在 PATH 里。
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
agent=${1:?usage: smoke.sh <agent> [agent-shim args...]}
shift
work=${WORKDIR:-$(mktemp -d)}
mkdir -p "$work"
token="sbx-smoke-$$-$RANDOM"

python3 "$root/tools/mock-llm/mock_llm.py" --port "${PORT:-0}" --token "$token" --log "$work/llm.jsonl" \
  ${DUMP:+--dump "$work/dump.jsonl"} >"$work/mock.out" 2>&1 &
mock=$!
trap 'kill $mock 2>/dev/null || true' EXIT
for _ in $(seq 50); do
  grep -q "listening on" "$work/mock.out" 2>/dev/null && break
  sleep 0.1
done
port=$(sed -n 's/listening on //p' "$work/mock.out")
start_line=$(wc -l <"$work/llm.jsonl")

trace=()
if [ -n "${EGRESS:-}" ]; then
  unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy
  : >"$work/egress.trace"
  trace=(strace -f -qq -xx -s 512 -e trace=connect,sendto,sendmmsg -o "$work/egress.trace")
fi

set +e
THINKTIN_SANDBOX_TOKEN=$token "${trace[@]}" "${SHIM:-$root/target/debug/agent-shim}" run \
  --agent "$agent" --home "$work/home" --cwd "$work/work" \
  --gateway "http://127.0.0.1:$port" --prompt "${PROMPT:-Say hi}" "$@" \
  >"$work/events.jsonl" 2>"$work/shim.log"
code=$?
set -e

python3 - "$work" "$code" "${EXPECT:-pong from mock}" "$start_line" "${EGRESS:-}" <<'PY'
import json, re, sys
work, code, expect, start, egress = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5]
events = [json.loads(l) for l in open(f"{work}/events.jsonl") if l.strip()]
calls = [json.loads(l) for l in open(f"{work}/llm.jsonl")][start:]
ready = next((e for e in events if e["type"] == "ready"), None)
ended = next((e for e in events if e["type"] == "turn_ended"), None)
reply = "".join(e["text"] for e in events if e["type"] == "message_chunk")
tools = [f'{e.get("kind")}:{e.get("title")}' for e in events if e["type"] == "tool_call"]
perms = [f'{e["by"]}->{e["option_id"]}' for e in events if e["type"] == "permission_resolved"]
errors = [e["message"][:300] for e in events if e["type"] == "error"]
model_calls = [c for c in calls if c["method"] == "POST" and "reply" in c]
bad_auth = [c for c in calls if c["method"] == "POST" and c.get("auth") != "ok"]
# 有的 agent（如 Hermes）会不带凭证探测网关是不是本地推理服务，这些 GET 只记录不判失败。
probes = sorted({c["path"] for c in calls if c["method"] == "GET" and c.get("auth") != "ok"})
checks = {
    "agent ready": ready is not None,
    "turn ended": ended is not None,
    f"reply contains {expect!r}": expect in reply,
    "model called via gateway": len(model_calls) > 0,
    "every model request used the sandbox token": not bad_auth,
}
print(f"agent:    {ready and ready['agent_id']} / {ready and ready['harness']}  ({ready and json.dumps(ready.get('agent_info'))})")
print(f"session:  {ready and ready['session_id']}  restored={ready and ready['session_restored']}")
print(f"stop:     {ended and ended['stop_reason']}   exit={code}")
print(f"reply:    {reply.strip()[:300]!r}")
print(f"tools:    {tools}")
print(f"perms:    {perms}")
print(f"requests: {[(c['path'], c.get('model'), c.get('reply') or c.get('error')) for c in calls]}")
if errors:
    print(f"errors:   {errors}")
if probes:
    print(f"probes without token (rejected by the real gateway): {probes}")
if egress:
    # 从 strace 记录里取出回环以外的连接和 DNS 查询（-xx 下字符串都是 \xHH 形式）。
    unhex = lambda h: bytes(int(x, 16) for x in h.split("\\x")[1:])
    remote, names = set(), set()
    for line in open(f"{work}/egress.trace", errors="replace"):
        if "connect(" in line:
            m = re.search(r'sin6?_port=htons\((\d+)\).*?(?:inet_addr\("|AF_INET6, ")([^"]+)"', line)
            if m:
                addr = m.group(2)
                addr = unhex(addr).decode() if addr.startswith("\\x") else addr
                if not (addr.startswith("127.") or addr in ("::1", "::ffff:127.0.0.1")):
                    remote.add(f"{addr}:{m.group(1)}")
        if "sendto(" in line or "sendmmsg(" in line:
            for h in re.findall(r'"((?:\\x[0-9a-f]{2})+)"', line):
                b = unhex(h)
                if len(b) < 17 or b[4:6] != b"\x00\x01":
                    continue
                i, labels = 12, []
                while i < len(b) and b[i] and len(labels) < 20:
                    labels.append(b[i + 1:i + 1 + b[i]].decode("ascii", "replace"))
                    i += b[i] + 1
                if labels:
                    names.add(".".join(labels))
    print(f"egress:   dns={sorted(names) or 'none'} connects={sorted(remote) or 'none'}")
    checks["no traffic outside the sandbox"] = not remote and not names
for name, ok in checks.items():
    print(f"  [{'ok' if ok else 'FAIL'}] {name}")
print(f"logs:     {work}")
sys.exit(0 if all(checks.values()) else 1)
PY

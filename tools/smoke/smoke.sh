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
# agent 的可执行文件（claude-agent-acp、codex-acp、pi-acp、openclaw、hermes-acp）要在 PATH 里。
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
agent=${1:?usage: smoke.sh <agent> [agent-shim args...]}
shift
work=${WORKDIR:-$(mktemp -d)}
mkdir -p "$work"
token="sbx-smoke-$$-$RANDOM"

python3 "$root/tools/mock-llm/mock_llm.py" --token "$token" --log "$work/llm.jsonl" \
  ${DUMP:+--dump "$work/dump.jsonl"} >"$work/mock.out" 2>&1 &
mock=$!
trap 'kill $mock 2>/dev/null || true' EXIT
for _ in $(seq 50); do
  grep -q "listening on" "$work/mock.out" 2>/dev/null && break
  sleep 0.1
done
port=$(sed -n 's/listening on //p' "$work/mock.out")
start_line=$(wc -l <"$work/llm.jsonl")

set +e
THINKTIN_SANDBOX_TOKEN=$token "${SHIM:-$root/target/debug/agent-shim}" run \
  --agent "$agent" --home "$work/home" --cwd "$work/work" \
  --gateway "http://127.0.0.1:$port" --prompt "${PROMPT:-Say hi}" "$@" \
  >"$work/events.jsonl" 2>"$work/shim.log"
code=$?
set -e

python3 - "$work" "$code" "${EXPECT:-pong from mock}" "$start_line" <<'PY'
import json, sys
work, code, expect, start = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
events = [json.loads(l) for l in open(f"{work}/events.jsonl") if l.strip()]
calls = [json.loads(l) for l in open(f"{work}/llm.jsonl")][start:]
ready = next((e for e in events if e["type"] == "ready"), None)
ended = next((e for e in events if e["type"] == "turn_ended"), None)
reply = "".join(e["text"] for e in events if e["type"] == "message_chunk")
tools = [f'{e.get("kind")}:{e.get("title")}' for e in events if e["type"] == "tool_call"]
perms = [f'{e["by"]}->{e["option_id"]}' for e in events if e["type"] == "permission_resolved"]
errors = [e["message"][:300] for e in events if e["type"] == "error"]
bad_auth = [c for c in calls if c.get("auth") != "ok"]
model_calls = [c for c in calls if c["method"] == "POST" and "reply" in c]
checks = {
    "agent ready": ready is not None,
    "turn ended": ended is not None,
    f"reply contains {expect!r}": expect in reply,
    "model called via gateway": len(model_calls) > 0,
    "every request used the sandbox token": not bad_auth,
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
for name, ok in checks.items():
    print(f"  [{'ok' if ok else 'FAIL'}] {name}")
print(f"logs:     {work}")
sys.exit(0 if all(checks.values()) else 1)
PY

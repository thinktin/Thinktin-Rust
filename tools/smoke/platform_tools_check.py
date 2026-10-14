#!/usr/bin/env python3
"""用真实 agent 检查平台工具桥（WBS 6.12）：agent 调平台工具 → shim 报 platform_tool_call → 平台回结果 → agent 拿到结果。

用法：tools/smoke/platform_tools_check.py <agent> [agent-shim serve 的其他参数...]
提示词让网关替身返回一次对 `*schedule_list` 的调用（各家 agent 给 MCP 工具加的前缀不同，按后缀匹配），
本脚本扮演平台：自动批准权限请求，回答工具调用，最后检查 agent 的回复里有平台给的结果。
GW=1 时走真实模型网关（见 gateway.py）。
"""

import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TIMEOUT = 240
TOOLS = [{
    "name": "schedule_list",
    "description": "List the user's schedules on the ThinkTin platform.",
    "input_schema": {"type": "object", "properties": {"limit": {"type": "integer"}}},
}]


def main():
    agent, extra = sys.argv[1], sys.argv[2:]
    work = tempfile.mkdtemp(prefix=f"ptools-{agent}-")
    via_gw = bool(os.environ.get("GW"))
    token = f"sbx-ptools-{os.getpid()}"
    vendor_key = f"sk-vendor-{os.getpid()}-0001"
    mock_args = ["--token", vendor_key, "--root", "/vendor", "--forbid", "tts1."] if via_gw else ["--token", token]
    mock = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "tools/mock-llm/mock_llm.py"), *mock_args,
         "--log", os.path.join(work, "llm.jsonl"),
         *(["--dump", os.path.join(work, "dump.jsonl")] if os.environ.get("DUMP") else [])],
        stdout=subprocess.PIPE, text=True)
    port = mock.stdout.readline().split()[-1]
    gw = None
    if via_gw:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import gateway
        gw, port, token, _ = gateway.start(work, port, vendor_key)
    tools_file = os.path.join(work, "tools.json")
    with open(tools_file, "w") as f:
        json.dump(TOOLS, f)
    shim = subprocess.Popen(
        [os.environ.get("SHIM", os.path.join(ROOT, "target/debug/agent-shim")), "serve", "--agent", agent,
         "--home", os.path.join(work, "home"), "--cwd", os.path.join(work, "work"),
         "--gateway", f"http://127.0.0.1:{port}", "--handshake-timeout-secs", "180",
         "--platform-tools", "--platform-tools-file", tools_file, *extra],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(os.path.join(work, "shim.log"), "w"),
        text=True, env=dict(os.environ, THINKTIN_SANDBOX_TOKEN=token))
    events = queue.Queue()
    threading.Thread(target=lambda: [events.put(json.loads(l)) for l in shim.stdout], daemon=True).start()

    def send(**cmd):
        shim.stdin.write(json.dumps(cmd) + "\n")
        shim.stdin.flush()

    calls, permissions, reply, ended = [], [], [], None
    deadline = time.time() + TIMEOUT
    try:
        while time.time() < deadline and ended is None:
            try:
                ev = events.get(timeout=1)
            except queue.Empty:
                continue
            ty = ev["type"]
            if ty == "ready":
                send(type="prompt", run_id="r1", text='Check my schedules. MOCK_TOOL:*schedule_list:{"limit": 2}')
            elif ty == "permission_requested":
                allow = next((o for o in ev["options"] if o["kind"].startswith("allow")), ev["options"][0])
                permissions.append(ev.get("title"))
                send(type="permission_decision", request_id=ev["request_id"], option_id=allow["option_id"])
            elif ty == "platform_tool_call":
                calls.append(ev)
                send(type="platform_tool_result", call_id=ev["call_id"],
                     content=[{"type": "text", "text": "PLATFORM_OK: daily-news at 08:00, weekly-report on Mon"}])
            elif ty == "message_chunk" and ev.get("run_id") == "r1":
                reply.append(ev["text"])
            elif ty == "turn_ended" and ev["run_id"] == "r1":
                ended = ev
            elif ty == "error":
                print(f"error: {ev['message'][:300]}")
    finally:
        send(type="shutdown")
        try:
            shim.wait(timeout=60)
        except subprocess.TimeoutExpired:
            shim.kill()
        mock.kill()
        if gw:
            gw.kill()

    text = "".join(reply)
    call = calls[0] if calls else {}
    checks = {
        "turn ended": ended is not None and ended["stop_reason"] == "end_turn",
        "agent called the platform tool once": len(calls) == 1,
        "call belongs to the running turn": call.get("run_id") == "r1",
        "tool name and arguments arrived": call.get("name") == "schedule_list" and call.get("arguments") == {"limit": 2},
        "agent saw the platform's answer": "PLATFORM_OK" in text,
    }
    print(f"permissions asked: {permissions}")
    print(f"reply: {text.strip()[:200]!r}")
    for name, ok in checks.items():
        print(f"  [{'ok' if ok else 'FAIL'}] {name}")
    print(f"logs: {work}")
    sys.exit(0 if all(checks.values()) else 1)


if __name__ == "__main__":
    main()

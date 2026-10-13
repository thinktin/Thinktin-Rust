#!/usr/bin/env python3
"""用真实 agent 检查 `agent-shim serve` 的取消：先跑一轮，再跑一轮慢的并中途取消，最后确认还能接着用。

用法：tools/smoke/serve_check.py <agent> [agent-shim serve 的其他参数...]
agent 的可执行文件要在 PATH 里；SHIM 指定 agent-shim 路径，默认 target/debug/agent-shim。
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
TIMEOUT = 180


def main():
    agent, extra = sys.argv[1], sys.argv[2:]
    work = tempfile.mkdtemp(prefix=f"serve-{agent}-")
    token = f"sbx-serve-{os.getpid()}"
    mock = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "tools/mock-llm/mock_llm.py"), "--token", token,
         "--log", os.path.join(work, "llm.jsonl")], stdout=subprocess.PIPE, text=True)
    port = mock.stdout.readline().split()[-1]
    shim = subprocess.Popen(
        [os.environ.get("SHIM", os.path.join(ROOT, "target/debug/agent-shim")), "serve", "--agent", agent,
         "--home", os.path.join(work, "home"), "--cwd", os.path.join(work, "work"),
         "--gateway", f"http://127.0.0.1:{port}", "--handshake-timeout-secs", "180", *extra],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(os.path.join(work, "shim.log"), "w"),
        text=True, env=dict(os.environ, THINKTIN_SANDBOX_TOKEN=token))
    events = queue.Queue()
    threading.Thread(target=lambda: [events.put(json.loads(l)) for l in shim.stdout], daemon=True).start()

    def send(**cmd):
        shim.stdin.write(json.dumps(cmd) + "\n")
        shim.stdin.flush()

    def wait(pred, what):
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            try:
                ev = events.get(timeout=1)
            except queue.Empty:
                continue
            if pred(ev):
                return ev
        raise SystemExit(f"timed out waiting for {what}; logs in {work}")

    ok = True
    try:
        wait(lambda e: e["type"] == "ready", "ready")
        send(type="prompt", run_id="r1", text="Say hi")
        end = wait(lambda e: e["type"] == "turn_ended" and e["run_id"] == "r1", "r1")
        print(f"r1 (normal):    {end['stop_reason']}")
        ok &= end["stop_reason"] == "end_turn"

        send(type="prompt", run_id="r2", text="Write a lot. MOCK_SLOW")
        wait(lambda e: e["type"] == "message_chunk" and e["run_id"] == "r2", "first chunk of r2")
        started = time.time()
        send(type="cancel", run_id="r2")
        end = wait(lambda e: e["type"] in ("turn_ended", "error") and e.get("run_id") == "r2", "r2 end")
        print(f"r2 (cancelled): {end.get('stop_reason', end.get('message'))} after {time.time() - started:.1f}s")
        ok &= end.get("stop_reason") == "cancelled"

        send(type="prompt", run_id="r3", text="Say hi again")
        end = wait(lambda e: e["type"] == "turn_ended" and e["run_id"] == "r3", "r3")
        print(f"r3 (after):     {end['stop_reason']}")
        ok &= end["stop_reason"] == "end_turn"
    finally:
        send(type="shutdown")
        shim.wait(timeout=60)
        mock.kill()
    print(f"{'PASS' if ok else 'FAIL'}  logs: {work}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

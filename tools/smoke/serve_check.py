#!/usr/bin/env python3
"""用真实 agent 检查 `agent-shim serve` 的取消：先跑一轮，再跑一轮慢的并中途取消，最后确认还能接着用。

用法：tools/smoke/serve_check.py <agent> [agent-shim serve 的其他参数...]
agent 的可执行文件要在 PATH 里；SHIM 指定 agent-shim 路径，默认 target/debug/agent-shim。
DUMP=1 时把完整请求体存到工作目录的 dump.jsonl。GW=1 时走真实模型网关（替身扮演厂商），并检查网关把取消的那次调用记成 client_closed、厂商没见过沙箱令牌。
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
    via_gw = bool(os.environ.get("GW"))
    token = f"sbx-serve-{os.getpid()}"
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
        # 等慢输出真的开始了再取消（Codex 每轮开头会先发一句模型元数据警告，不能拿它当信号）。
        wait(lambda e: e["type"] == "message_chunk" and e["run_id"] == "r2" and "slow" in e.get("text", ""),
             "slow output of r2")
        started = time.time()
        send(type="cancel", run_id="r2")
        end = wait(lambda e: e["type"] in ("turn_ended", "error") and e.get("run_id") == "r2", "r2 end")
        print(f"r2 (cancelled): {end.get('stop_reason', end.get('message'))} after {time.time() - started:.1f}s")
        ok &= end.get("stop_reason") == "cancelled"

        send(type="prompt", run_id="r3", text="Say hi again")
        end = wait(lambda e: e["type"] == "turn_ended" and e["run_id"] == "r3", "r3")
        print(f"r3 (after):     {end['stop_reason']}")
        ok &= end["stop_reason"] == "end_turn"
        if via_gw:
            time.sleep(0.5)
            records = gateway.usage_records(work)
            outcomes = [r["outcome"] for r in records]
            calls = [json.loads(l) for l in open(os.path.join(work, "llm.jsonl"))]
            leaks = [c["path"] for c in calls if c.get("forbidden_seen")]
            print(f"gateway:        {outcomes}")
            print(f"vendor leaks:   {leaks or 'none'}")
            ok &= "client_closed" in outcomes and outcomes.count("complete") >= 2 and not leaks
    finally:
        send(type="shutdown")
        shim.wait(timeout=60)
        mock.kill()
        if gw:
            gw.kill()
    print(f"{'PASS' if ok else 'FAIL'}  logs: {work}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

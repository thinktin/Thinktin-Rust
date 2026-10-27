#!/usr/bin/env python3
"""起一个真实的模型网关（llm-gw），后面接扮演厂商的网关替身。供 smoke.sh 和 serve_check.py 使用。

用法：gateway.py <工作目录> <厂商替身端口> <厂商 key> [网关端口]
打印一行 "<网关进程号> <网关端口> <沙箱令牌>"。网关日志（JSON）追加到 <工作目录>/gw.log。
GW_BIN 指定 llm-gw 路径，默认 target/debug/llm-gw。

网关配置：用户 user-smoke 的实例 inst-smoke（沙箱 sbx-smoke），别名 main、fast 分别指向上游模型 up-main、up-fast，
凭证是 custom 厂商，地址指向替身的 /vendor 前缀。令牌绑定来源地址 127.0.0.1。
"""

import json
import os
import re
import secrets
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def start(work, vendor_port, vendor_key, port=0):
    gw_bin = os.environ.get("GW_BIN") or os.path.join(ROOT, "target/debug/llm-gw")
    run = lambda args, **kw: subprocess.run([gw_bin, *args], capture_output=True, text=True, check=True, **kw).stdout
    keys = run(["keygen", "--kid", "smoke"])
    seed = re.search(r"^THINKTIN_DEV_TOKEN_SEED=(\S+)", keys, re.M).group(1)
    token_key = re.search(r"^--token-key (\S+)", keys, re.M).group(1)
    env = dict(os.environ, THINKTIN_DEV_KMS_KEY=secrets.token_hex(32))

    store = os.path.join(work, "gw-store.json")
    if os.path.exists(store):
        os.remove(store)
    vendor = f"http://127.0.0.1:{vendor_port}/vendor"
    run(["put-key", "--store", store, "--id", "cred-smoke", "--user", "user-smoke", "--vendor", "custom",
         "--anthropic-base", f"{vendor}/anthropic", "--openai-base", f"{vendor}/openai/v1", "--responses"],
        input=vendor_key, env=env)
    data = json.load(open(store))
    data["instances"] = [{
        "id": "inst-smoke", "user_id": "user-smoke", "sandbox": "sbx-smoke",
        "routes": {alias: {"credential": "cred-smoke", "model": f"up-{alias}"} for alias in ("main", "fast")},
    }]
    json.dump(data, open(store, "w"), indent=2)

    log_path = os.path.join(work, "gw.log")
    skip = sum(1 for _ in open(log_path)) if os.path.exists(log_path) else 0
    proc = subprocess.Popen(
        [gw_bin, "serve", "--listen", f"127.0.0.1:{port}", "--store", store, "--token-key", token_key,
         "--insecure-upstreams", "--log-json"],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=open(log_path, "a"), env=env)
    deadline = time.time() + 10
    while time.time() < deadline:
        for line in open(log_path).read().splitlines()[skip:]:
            m = re.search(r'"addr":"127\.0\.0\.1:(\d+)"', line)
            if m:
                token = run(["issue-token", "--kid", "smoke", "--instance", "inst-smoke", "--user", "user-smoke",
                             "--sandbox", "sbx-smoke", "--net", "127.0.0.1"],
                            env=dict(os.environ, THINKTIN_DEV_TOKEN_SEED=seed)).strip()
                return proc, int(m.group(1)), token, skip
        if proc.poll() is not None:
            break
        time.sleep(0.1)
    proc.kill()
    raise SystemExit(f"llm-gw did not start; see {log_path}")


def usage_records(work, skip=0):
    """网关从第 skip 行起记下的计量记录。"""
    lines = open(os.path.join(work, "gw.log")).read().splitlines()[skip:]
    return [json.loads(json.loads(l)["fields"]["usage"]) for l in lines if '"llm_gw::usage"' in l]


if __name__ == "__main__":
    work, vendor_port, vendor_key = sys.argv[1], sys.argv[2], sys.argv[3]
    proc, port, token, _ = start(work, vendor_port, vendor_key, int(sys.argv[4]) if len(sys.argv) > 4 else 0)
    print(proc.pid, port, token)

"""本机浏览器冒烟测试的假出口代理和测试网站（docs/browser.md 第 8.2 节）。

用法（另开一个终端先跑这个，再跑 agent-shim 里忽略的测试 `browser_smoke`）：

    python3 tools/smoke/browser_local.py pass-123 18791 18443 /tmp/browser-smoke.jsonl
    # Playwright MCP 装在某个目录 D 里，并拷入 deploy/templates/browser/*.cjs、打过补丁、生成 tools.json：
    #   npm i --prefix D @playwright/mcp@0.0.84 && cp deploy/templates/browser/*.cjs D/ \
    #   && node D/patch-playwright.cjs D/node_modules && node D/list-tools.cjs > D/tools.json
    THINKTIN_BROWSER_SMOKE_PROXY=127.0.0.1:18791 THINKTIN_BROWSER_SMOKE_PORT=18443 \
    THINKTIN_BROWSER_CHROMIUM=<chromium> THINKTIN_BROWSER_NODE=$(which node) THINKTIN_BROWSER_DIR=D \
    THINKTIN_BROWSER_ARGS="--ignore-certificate-errors --no-sandbox" \
    cargo test -p agent-shim --bin agent-shim browser_smoke -- --ignored

- 假出口代理：POST /v1/browser/ask 按名单回答（allow.* → allowed once，deny.* → denied，其余 pending）；
  CONNECT 要求 Basic browser:<pass>，把 *.test 连到本机的测试网站，记下 X-Thinktin-Browser 头。
- 测试网站：https，自签证书（Chromium 用 --ignore-certificate-errors），首页引用另一个网站的图片。
"""
import asyncio, base64, json, os, ssl, subprocess, sys, tempfile

PASS = sys.argv[1]
PROXY_PORT = int(sys.argv[2])
SITE_PORT = int(sys.argv[3])
LOG = sys.argv[4]

def log(entry):
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")

async def read_head(r):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = await r.read(1024)
        if not chunk:
            break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    return head.decode("latin1"), rest

async def pipe(r, w):
    try:
        while True:
            b = await r.read(65536)
            if not b:
                break
            w.write(b)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass

async def proxy(r, w):
    head, rest = await read_head(r)
    lines = head.split("\r\n")
    method, target, _ = lines[0].split(" ", 2)
    headers = {}
    for l in lines[1:]:
        k, _, v = l.partition(":")
        headers[k.strip().lower()] = v.strip()
    if method == "POST" and target == "/v1/browser/ask":
        n = int(headers.get("content-length", "0"))
        body = rest
        while len(body) < n:
            body += await r.read(n - len(body))
        ask = json.loads(body)
        ok = headers.get("authorization") == f"Bearer {PASS}"
        host = ask["host"]
        if not ok:
            reply = {"result": "auth"}
        elif host.startswith("dev"):
            # 开发网站这类：代理直接放行，没问用户（不带 request_id）。
            reply = {"result": "allowed", "scope": "default"}
        elif host.startswith("allow") or host.startswith("site"):
            # 问了用户、用户点了“访问一次”。
            reply = {"result": "allowed", "scope": "once", "request_id": "req-0"}
        elif host.startswith("deny"):
            reply = {"result": "denied"}
        else:
            reply = {"result": "pending", "request_id": "req-1"}
        log({"ask": ask, "reply": reply})
        out = json.dumps(reply).encode()
        w.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(out), out))
        await w.drain()
        w.close()
        return
    if method != "CONNECT":
        w.write(b"HTTP/1.1 405 No\r\n\r\n"); w.close(); return
    cred = headers.get("proxy-authorization", "")
    expect = "Basic " + base64.b64encode(f"browser:{PASS}".encode()).decode()
    log({"connect": target, "auth_ok": cred == expect, "browser": headers.get("x-thinktin-browser")})
    if cred != expect:
        w.write(b"HTTP/1.1 407 No\r\n\r\n"); w.close(); return
    host, port = target.rsplit(":", 1)
    if not host.endswith(".test"):
        w.write(b"HTTP/1.1 403 No\r\n\r\n"); w.close(); return
    ur, uw = await asyncio.open_connection("127.0.0.1", SITE_PORT)
    w.write(b"HTTP/1.1 200 OK\r\n\r\n")
    await w.drain()
    if rest:
        uw.write(rest)
    await asyncio.gather(pipe(r, uw), pipe(ur, w))

PAGES = {
    "site.test": "<html><head><title>Site</title></head><body><h1>Hello from site</h1>"
                 "<img src='https://cdn.test:%d/img.png'><a href='https://other.test:%d/'>other</a></body></html>",
    "other.test": "<html><body><h1>Other site</h1></body></html>",
    "allow.test": "<html><body><h1>Allowed site</h1></body></html>",
}

async def site(r, w):
    head, _ = await read_head(r)
    lines = head.split("\r\n")
    if not lines or " " not in lines[0]:
        w.close(); return
    path = lines[0].split(" ")[1]
    host = ""
    for l in lines[1:]:
        if l.lower().startswith("host:"):
            host = l.split(":", 1)[1].strip().split(":")[0]
    log({"site": host, "path": path})
    if path.endswith(".png"):
        body = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
        ctype = b"image/png"
    else:
        body = (PAGES.get(host, "<h1>%s</h1>" % host) % (SITE_PORT, SITE_PORT) if host == "site.test" else PAGES.get(host, "<h1>%s</h1>" % host)).encode()
        ctype = b"text/html"
    w.write(b"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % (ctype, len(body)) + body)
    await w.drain()
    w.close()

async def main():
    # 自签证书，放在临时目录里。
    d = tempfile.mkdtemp()
    cert, key = os.path.join(d, "cert.pem"), os.path.join(d, "key.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                    "-days", "2", "-subj", "/CN=site.test"], check=True, capture_output=True)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    s1 = await asyncio.start_server(proxy, "127.0.0.1", PROXY_PORT)
    s2 = await asyncio.start_server(site, "127.0.0.1", SITE_PORT, ssl=ctx)
    print("ready", flush=True)
    await asyncio.gather(s1.serve_forever(), s2.serve_forever())

asyncio.run(main())

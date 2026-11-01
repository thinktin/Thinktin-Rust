"""Probe HTTPS proxy discovery by local developer tools, without contacting a public site."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST = "thinktin-egress-probe.invalid"
URL = f"https://{HOST}/"


class ProxyProbe(BaseHTTPRequestHandler):
    def do_CONNECT(self):
        self.server.targets.append(self.path)
        self.send_error(403)

    def log_message(self, fmt, *args):
        pass


def main():
    # 403 is intentional. The observed CONNECT, rather than a client's exit code,
    # tells us whether the client sent its target hostname to the explicit proxy.
    clients = [
        ("curl", ["curl", "-q", "--max-time", "5", URL], {}),
        ("git HTTPS", ["git", "ls-remote", URL], {"GIT_CONFIG_NOSYSTEM": "1"}),
        ("Python urllib", [sys.executable, "-I", "-c",
                           "import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=5)",
                           URL], {}),
    ]
    if shutil.which("node"):
        clients.append(("Node fetch", ["node", "-e",
                        "fetch(process.argv[1], {signal: AbortSignal.timeout(5000)})"
                        ".catch(() => process.exitCode = 1)", URL],
                        {"NODE_USE_ENV_PROXY": "1"}))
    else:
        print("SKIP Node fetch (node unavailable)")

    with tempfile.TemporaryDirectory() as home, ThreadingHTTPServer(("127.0.0.1", 0), ProxyProbe) as proxy:
        proxy.targets = []
        server = threading.Thread(target=proxy.serve_forever)
        server.start()
        try:
            address = f"http://127.0.0.1:{proxy.server_port}"
            env = {"PATH": os.environ["PATH"], "HOME": home, "XDG_CONFIG_HOME": home,
                   "http_proxy": address, "https_proxy": address, "HTTPS_PROXY": address,
                   "no_proxy": "localhost,127.0.0.1", "GIT_TERMINAL_PROMPT": "0"}
            for name, command, settings in clients:
                proxy.targets.clear()
                subprocess.run(command, cwd=Path(home), env={**env, **settings}, timeout=12,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                if not proxy.targets or set(proxy.targets) != {f"{HOST}:443"}:
                    raise RuntimeError(f"{name}: expected CONNECT to {HOST}:443, got {proxy.targets}")
                print(f"PASS {name}: CONNECT {HOST}:443")
        finally:
            proxy.shutdown()
            server.join()


if __name__ == "__main__":
    main()

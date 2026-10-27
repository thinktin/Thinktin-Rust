"""沙箱实测（docs/deploy-aliyun-sg.md 第 6 节）：建最小的沙箱，测完马上删。两种：

- **容器版**（`--acs`，正式用的）：ACS 集群里的 Agent Sandbox。先用 `run.sh acs` 装好组件、建好预热池，它把 sandbox-manager 的
  domain 和 adminApiKey 存在 target/aliyun-acs/sandbox.json。这里自己起 `kubectl port-forward`，走 OpenKruise 的私有协议（HTTP）。
- **极速版**（备选）：API Key 从环境变量 ALIYUN_SANDBOX_API_KEY 读（智能体沙箱控制台建的，不是 AccessKey）。

都不打印 Key。

    deploy/aliyun/run.sh sandbox --acs              只读：连上沙箱管理器，列现有沙箱
    deploy/aliyun/run.sh sandbox --acs --apply      建 2 个沙箱（第 1 个从预热池拿），测完删掉
    deploy/aliyun/run.sh sandbox [--apply]          极速版：只读找接口地址、列模板；--apply 建 1 个沙箱测完删掉

--apply 测这些：
- 冷启动多久、实际给了几核几 G
- 跑命令、读写文件
- 元数据地址 100.100.100.200 连不连得上（连得上就可能拿到云上的临时凭证）
- 默认出网：连不连得上模型厂商
- 暂停和恢复各要多久、恢复后文件还在不在
- 容器版另外测：两个沙箱之间通不通（应该不通）、很久没输出的命令会不会被断（--idle 秒数，0 不测）

沙箱建的时候设了超时、到期删除，脚本中途出错也不会一直计费。
"""

import argparse
import contextlib
import json
import os
import socket
import subprocess
import sys
import time

import httpx
from e2b import ConnectionConfig, Sandbox
from e2b.exceptions import AuthenticationException, FileNotFoundException

KEY = "ALIYUN_SANDBOX_API_KEY"
DOMAIN = "ALIYUN_SANDBOX_DOMAIN"  # 可选：直接指定接口域名，不用自动找
# 极速版的地址；函数计算云沙箱的地址也试一下，Key 是哪边建的就能用哪边。
DOMAINS = ["{region}.sandbox.aliyuncs.com", "{region}.e2b.fc.aliyuncs.com"]
FALLBACK_TEMPLATE = "code-interpreter-v1"  # 阿里云文档示例用的模板
TIMEOUT = 600
PROBE_FILE = "thinktin-probe.txt"
# 出网检查：只看 443 端口的 TCP 能不能连上，不发请求。
VENDORS = ["api.anthropic.com", "api.openai.com", "api.x.ai", "generativelanguage.googleapis.com"]

# 容器版（run.sh acs 准备的）
ACS_DIR = "target/aliyun-acs"
ACS_STATE = f"{ACS_DIR}/sandbox.json"
KUBECONFIG = f"{ACS_DIR}/kubeconfig"
KUBECTL = "target/bin/kubectl"
ACS_TEMPLATE = "code-interpreter"  # 预热池 SandboxSet 的名字
ACS_TIMEOUT = 1800
PEER_PORT = 8000
PURPOSE = {"purpose": "thinktin-probe"}  # 建沙箱时打的标记，收尾时按它找漏删的
COST = "要收费（按秒计，每个沙箱 1 核 1G，测十来分钟；预热池被拿走后会马上补 1 个）：用户同意了再加 --apply"

rows = []


def record(item, result):
    rows.append((item, result))
    print(f"  {item}：{result}")


def timed(fn):
    start = time.monotonic()
    value = fn()
    return value, time.monotonic() - start


def tcp(host, port):
    """沙箱里用 bash 的 /dev/tcp 测连通，不依赖模板里有没有 curl。"""
    return f"timeout 5 bash -c 'exec 3<>/dev/tcp/{host}/{port}' 2>/dev/null && echo 通 || echo 不通"


def find_domain(region, key):
    override = os.environ.get(DOMAIN, "").strip()
    candidates = [override] if override else [d.format(region=region) for d in DOMAINS]
    for domain in candidates:
        try:
            Sandbox.list(api_key=key, domain=domain, validate_api_key=False, limit=1).next_items()
            return domain
        except AuthenticationException:
            print(f"  {domain}：Key 不认")
    return None


def list_templates(domain, key):
    resp = httpx.get(f"https://api.{domain}/templates", headers={"X-API-KEY": key}, timeout=30)
    resp.raise_for_status()
    return resp.json()


def template_name(t):
    aliases = t.get("aliases") or []
    return aliases[0] if aliases else t.get("templateID")


def run(sbx, cmd, timeout=60):
    return sbx.commands.run(cmd, timeout=timeout).stdout.strip()


def basics(sbx):
    info = sbx.get_info()
    record("规格", f"{info.cpu_count} 核 {info.memory_mb} MB，envd {info.envd_version}")
    record("系统", run(sbx, "uname -r; nproc; free -m | awk 'NR==2{print $2\" MB 内存\"}'; df -h / | awk 'NR==2{print $2\" 磁盘\"}'").replace("\n", "，"))

    token = f"thinktin {time.time()}"
    sbx.files.write(PROBE_FILE, token)
    record("读写文件", "通过" if sbx.files.read(PROBE_FILE) == token else "读回来的内容不一致")

    record("元数据地址 100.100.100.200:80", run(sbx, tcp("100.100.100.200", 80)) + "（应该不通）")
    for host in VENDORS:
        record(f"出网 {host}:443", run(sbx, tcp(host, 443)))
    return token


def pause_resume(sbx, opts, token, timeout):
    try:
        _, paused = timed(sbx.beta_pause)
    except Exception as err:  # noqa: BLE001 —— 暂停不可用也接着测完
        record("暂停", f"不可用：{type(err).__name__}: {str(err).splitlines()[0][:200]}")
        return sbx
    record("暂停", f"{paused:.1f} 秒")
    state = Sandbox.get_info(sbx.sandbox_id, **opts).state
    record("暂停后状态", str(state))
    try:
        resumed, took = timed(lambda: Sandbox.connect(sbx.sandbox_id, timeout=timeout, **opts))
    except Exception as err:  # noqa: BLE001 —— 恢复失败也要把结果报完
        record("恢复", f"失败：{type(err).__name__}: {str(err).splitlines()[0][:200]}")
        return sbx
    record("恢复", f"{took:.1f} 秒")
    try:
        record("恢复后文件", "还在" if resumed.files.read(PROBE_FILE) == token else "内容变了")
    except FileNotFoundException:
        record("恢复后文件", "丢了")
    return resumed


def probe(sbx, opts):
    token = basics(sbx)
    return pause_resume(sbx, opts, token, TIMEOUT)


def kruise_patch():
    """容器版走 OpenKruise 的私有协议，不用泛域名和证书：管理接口是 http://<domain>/kruise/api（创建时传 api_url），
    沙箱里的端口是 http://<domain>/kruise/<沙箱 id>/<端口>。和 openkruise/agents 的 sdk/customized_e2b 里
    patch_e2b(https=False) 做的一样（只用 envd，不用 code-interpreter 的 Jupyter），没装那个包。
    port-forward 只有本机一个入口，所以一律连自己的 domain，不用服务端报回来的。"""

    def get_host(self, sandbox_id, sandbox_domain, port):
        return f"{self.domain}/kruise/{sandbox_id}/{port}"

    def get_sandbox_url(self, sandbox_id, sandbox_domain):
        return f"http://{self.get_host(sandbox_id, sandbox_domain, self.envd_port)}"

    ConnectionConfig.get_host = get_host
    ConnectionConfig.get_sandbox_url = get_sandbox_url


@contextlib.contextmanager
def port_forward(service_port, local_port):
    """kubectl port-forward 到 sandbox-system 的 sandbox-manager，用完关掉。"""
    proc = subprocess.Popen(
        [KUBECTL, "--kubeconfig", KUBECONFIG, "port-forward", "-n", "sandbox-system",
         "services/sandbox-manager", f"{local_port}:{service_port}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
    )
    try:
        deadline = time.monotonic() + 30
        while True:
            if proc.poll() is not None:
                raise RuntimeError(f"port-forward 退出了：{proc.stderr.read().strip()[:300]}")
            try:
                socket.create_connection(("127.0.0.1", local_port), timeout=1).close()
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise TimeoutError("port-forward 30 秒没连上") from None
                time.sleep(0.5)
        yield
    finally:
        proc.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=10)


def own_ip(sbx):
    # UDP 的 connect 不发包，只是让系统选出口地址；不依赖镜像里有没有 ip、hostname -I。
    return run(sbx, "python3 -c \"import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); "
                    "s.connect(('10.255.255.255', 1)); print(s.getsockname()[0])\"")


def isolation(a, b):
    """在 a 里起一个监听，先从 a 自己连（证明监听在），再从 b 连（应该不通）；两边的 envd 端口也互相试。"""
    ip_a, ip_b = own_ip(a), own_ip(b)
    record("沙箱地址", f"A {ip_a}，B {ip_b}")
    a.commands.run(f"nohup python3 -m http.server {PEER_PORT} >/dev/null 2>&1 &", timeout=30)
    time.sleep(2)
    record(f"A 连自己 {PEER_PORT}", run(a, tcp(ip_a, PEER_PORT)) + "（应该通，不通的话下面的结果不作数）")
    record(f"B → A:{PEER_PORT}", run(b, tcp(ip_a, PEER_PORT)) + "（应该不通）")
    envd = ConnectionConfig.envd_port
    record(f"B → A:{envd}（envd）", run(b, tcp(ip_a, envd)) + "（应该不通）")
    record(f"A → B:{envd}（envd）", run(a, tcp(ip_b, envd)) + "（应该不通）")


def idle(sbx, seconds):
    """跑一个很久没输出的命令，看连接会不会被断（等审批时 agent 可能很久没输出）。"""
    start = time.monotonic()
    try:
        out = run(sbx, f"sleep {seconds}; echo 还在", timeout=seconds + 60)
        record(f"{seconds} 秒没输出", f"{'没断' if out == '还在' else '输出不对：' + out[:100]}，用了 {time.monotonic() - start:.0f} 秒")
    except Exception as err:  # noqa: BLE001 —— 断了也要记下是怎么断的
        record(f"{seconds} 秒没输出", f"{time.monotonic() - start:.0f} 秒时断了：{type(err).__name__}: {str(err).splitlines()[0][:200]}")


def in_cloud_session():
    return os.environ.get("CLAUDE_CODE_REMOTE") == "true"


def pool_status():
    out = subprocess.run([KUBECTL, "--kubeconfig", KUBECONFIG, "get", "sandboxset", ACS_TEMPLATE, "-n", "default",
                          "--no-headers"], capture_output=True, text=True)
    return " ".join(out.stdout.split()) or "查不到"


def cleanup(opts, before, made):
    """删掉这次建的沙箱：create 抛错但服务端已经建好的也算（按标记、按建之前没有的 ID 找）。"""
    for sid in made:
        with contextlib.suppress(Exception):
            Sandbox.kill(sid, **opts)
    try:
        now = Sandbox.list(**opts).next_items()
    except Exception as err:  # noqa: BLE001 —— 查不了也要说清楚
        record("删除", f"没确认（{type(err).__name__}），可能还有沙箱在跑，{ACS_TIMEOUT // 60} 分钟后到期自动删；"
                     f"用 kubectl 核对：{', '.join(made) or '-'}")
        return
    ours = [s.sandbox_id for s in now if s.sandbox_id not in before and (s.metadata or {}).get("purpose") == PURPOSE["purpose"]]
    for sid in ours:
        with contextlib.suppress(Exception):
            Sandbox.kill(sid, **opts)
    try:
        left = {s.sandbox_id for s in Sandbox.list(**opts).next_items()} & (set(made) | set(ours))
    except Exception:  # noqa: BLE001
        left = set(ours)
    record("删除", "已删" if not left else f"没删掉，用 kubectl 或控制台手动删 {', '.join(sorted(left))}")


def main_acs(args):
    if in_cloud_session():
        print("[不通过] 云端会话连不上集群：port-forward 要连 API Server 的 6443 端口、带客户端证书、走 WebSocket，出网代理都不支持。"
              "要在集群 VPC 里的机器上跑，见 docs/handoff.md。")
        return 1
    try:
        with open(ACS_STATE) as f:
            state = json.load(f)
        key, domain = state["api_key"], state.get("domain", "localhost")
    except (FileNotFoundError, KeyError, ValueError):
        print(f"[不通过] 没有 {ACS_STATE}：先 `deploy/aliyun/run.sh acs --addons --apply` 装沙箱组件（要用户同意）。")
        return 1
    if domain != "localhost":
        print(f"[不通过] sandbox-manager 的 domain 是 {domain}：port-forward 测试要装成 localhost（run.sh acs --addons --domain localhost）。")
        return 1
    service_port, local_port = state.get("service_port", 7788), 80
    opts = {"api_key": key, "domain": domain, "api_url": f"http://{domain}/kruise/api"}
    kruise_patch()
    print(f"Key：已读到（不显示）。port-forward 本机 {local_port} → sandbox-manager {service_port}\n")
    with port_forward(service_port, local_port):
        running = Sandbox.list(**opts).next_items()
        print(f"现有沙箱 {len(running)} 个" + "".join(f"\n  {s.sandbox_id}（{s.template_id}，{s.state}）" for s in running))
        if not args.apply:
            print(f"\n加 --apply 用模板 {args.template or ACS_TEMPLATE} 建 2 个沙箱，测完删掉。{COST}。")
            return 0
        template = args.template or ACS_TEMPLATE
        before = {s.sandbox_id for s in running}
        made = []

        def create(label):
            pool = pool_status()
            sbx, took = timed(lambda: Sandbox.create(template=template, timeout=ACS_TIMEOUT, metadata=PURPOSE, **opts))
            made.append(sbx.sandbox_id)
            record(f"冷启动 {label}", f"{took:.1f} 秒，{sbx.sandbox_id}（建之前预热池：{pool}）")
            return sbx

        print(f"\n建沙箱（模板 {template}，{ACS_TIMEOUT // 60} 分钟超时到期删除）：")
        try:
            a = create("A")
            token = basics(a)
            b = create("B")
            isolation(a, b)
            if args.idle:
                idle(b, args.idle)
            pause_resume(a, opts, token, ACS_TIMEOUT)
        finally:
            cleanup(opts, before, made)
    report()
    return 0


def report():
    print("\n结果（贴进 docs/deploy-aliyun-sg.md 第 8.6 节）：")
    for item, result in rows:
        print(f"- {item}：{result}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--template", help="模板名或 ID（默认选核数和内存最小的）")
    parser.add_argument("--apply", action="store_true", help="真的建沙箱（要收费，先问用户），测完删掉（默认只读）")
    parser.add_argument("--acs", action="store_true", help="测 ACS 容器版（先用 run.sh acs 准备好）")
    parser.add_argument("--idle", type=int, default=300, help="容器版：多少秒没输出的命令（0 不测）")
    args = parser.parse_args()
    if args.acs:
        return main_acs(args)

    key = os.environ.get(KEY, "").strip()
    if not key:
        print(f"[不通过] 环境变量里没有 {KEY}。")
        print("      → 智能体沙箱控制台（新加坡）开通极速版、建 API Key，填进云端环境设置的“环境变量”，保存后开新会话。")
        return 1
    print(f"Key：已读到（不显示）。地域：{args.region}\n")

    print("找接口地址：")
    domain = find_domain(args.region, key)
    if not domain:
        print("[不通过] 两个地址都不认这个 Key：确认是新加坡地域建的、复制完整、前后没有空格。")
        return 1
    print(f"  用 {domain}\n")
    opts = {"api_key": key, "domain": domain, "validate_api_key": False}

    print("模板：")
    try:
        templates = list_templates(domain, key)
        for t in templates:
            print(f"  {template_name(t)}：{t.get('cpuCount')} 核 {t.get('memoryMB')} MB")
    except Exception as err:  # noqa: BLE001 —— 列不出来就用文档里的模板
        templates = []
        print(f"  列不出来（{type(err).__name__}: {str(err)[:120]}），用 {FALLBACK_TEMPLATE}")
    template = args.template
    if not template:
        sized = [t for t in templates if t.get("cpuCount") and t.get("memoryMB")]
        template = template_name(min(sized, key=lambda t: (t["cpuCount"], t["memoryMB"]))) if sized else FALLBACK_TEMPLATE

    running = Sandbox.list(**opts).next_items()
    print(f"\n现有沙箱 {len(running)} 个" + "".join(f"\n  {s.sandbox_id}（{s.template_id}，{s.state}）" for s in running))

    if not args.apply:
        print(f"\n加 --apply 用模板 {template} 建 1 个沙箱，测完删掉。{COST}。")
        return 0

    print(f"\n建沙箱（模板 {template}，{TIMEOUT // 60} 分钟超时到期删除）：")
    sbx, took = timed(lambda: Sandbox.create(template=template, timeout=TIMEOUT, metadata=PURPOSE, **opts))
    record("冷启动", f"{took:.1f} 秒，{sbx.sandbox_id}")
    try:
        sbx = probe(sbx, opts)
    finally:
        killed = Sandbox.kill(sbx.sandbox_id, **opts)
        left = [s.sandbox_id for s in Sandbox.list(**opts).next_items() if s.sandbox_id == sbx.sandbox_id]
        record("删除", "已删" if killed and not left else f"没删掉，到控制台手动删 {sbx.sandbox_id}")

    report()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # noqa: BLE001 —— 一行说清楚哪里错了
        print(f"[失败] {type(err).__name__}: {str(err).splitlines()[0][:300] if str(err) else ''}")
        sys.exit(1)

"""沙箱实测（docs/deploy-aliyun-sg.md 第 6 节）：在智能体沙箱极速版里建一个最小的沙箱，测完马上删。

用阿里云文档推荐的 E2B SDK。API Key 从环境变量 ALIYUN_SANDBOX_API_KEY 读（智能体沙箱控制台建的，不是 AccessKey），不打印。

    deploy/aliyun/run.sh sandbox            只读：找出 Key 能用的接口地址，列模板和现有沙箱
    deploy/aliyun/run.sh sandbox --apply    建 1 个沙箱（选最小的模板），测完删掉；几分钟，不到 1 毛钱

--apply 测这些：
- 冷启动多久、实际给了几核几 G
- 跑命令、读写文件
- 元数据地址 100.100.100.200 连不连得上（连得上就可能拿到云上的临时凭证）
- 默认出网：连不连得上模型厂商
- 暂停和恢复各要多久、恢复后文件还在不在（阿里云文档说暂停要开白名单，没开会报错，照实记下）

沙箱建的时候设了 10 分钟超时、到期删除，脚本中途出错也不会一直计费。
"""

import argparse
import os
import sys
import time

import httpx
from e2b import Sandbox
from e2b.exceptions import AuthenticationException

KEY = "ALIYUN_SANDBOX_API_KEY"
DOMAIN = "ALIYUN_SANDBOX_DOMAIN"  # 可选：直接指定接口域名，不用自动找
# 极速版的地址；函数计算云沙箱的地址也试一下，Key 是哪边建的就能用哪边。
DOMAINS = ["{region}.sandbox.aliyuncs.com", "{region}.e2b.fc.aliyuncs.com"]
FALLBACK_TEMPLATE = "code-interpreter-v1"  # 阿里云文档示例用的模板
TIMEOUT = 600
PROBE_FILE = "thinktin-probe.txt"
# 出网检查：只看 443 端口的 TCP 能不能连上，不发请求。
VENDORS = ["api.anthropic.com", "api.openai.com", "api.x.ai", "generativelanguage.googleapis.com"]

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


def run(sbx, cmd):
    return sbx.commands.run(cmd, timeout=60).stdout.strip()


def probe(sbx, opts):
    info = sbx.get_info()
    record("规格", f"{info.cpu_count} 核 {info.memory_mb} MB，envd {info.envd_version}")
    record("系统", run(sbx, "uname -r; nproc; free -m | awk 'NR==2{print $2\" MB 内存\"}'; df -h / | awk 'NR==2{print $2\" 磁盘\"}'").replace("\n", "，"))

    token = f"thinktin {time.time()}"
    sbx.files.write(PROBE_FILE, token)
    record("读写文件", "通过" if sbx.files.read(PROBE_FILE) == token else "读回来的内容不一致")

    record("元数据地址 100.100.100.200:80", run(sbx, tcp("100.100.100.200", 80)) + "（应该不通）")
    for host in VENDORS:
        record(f"出网 {host}:443", run(sbx, tcp(host, 443)))

    try:
        _, paused = timed(sbx.pause)
    except Exception as err:  # noqa: BLE001 —— 暂停要白名单，失败也接着测完
        record("暂停", f"不可用：{type(err).__name__}: {str(err).splitlines()[0][:200]}")
        return sbx
    record("暂停", f"{paused:.1f} 秒")
    state = Sandbox.get_info(sbx.sandbox_id, **opts).state
    record("暂停后状态", str(state))
    resumed, took = timed(lambda: Sandbox.connect(sbx.sandbox_id, timeout=TIMEOUT, **opts))
    record("恢复", f"{took:.1f} 秒")
    record("恢复后文件", "还在" if resumed.files.read(PROBE_FILE) == token else "丢了")
    return resumed


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-southeast-1")
    parser.add_argument("--template", help="模板名或 ID（默认选核数和内存最小的）")
    parser.add_argument("--apply", action="store_true", help="真的建沙箱，测完删掉（默认只读）")
    args = parser.parse_args()

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
        print(f"\n加 --apply 用模板 {template} 建 1 个沙箱，测完删掉。")
        return 0

    print(f"\n建沙箱（模板 {template}，{TIMEOUT // 60} 分钟超时到期删除）：")
    sbx, took = timed(lambda: Sandbox.create(template=template, timeout=TIMEOUT, metadata={"purpose": "thinktin-probe"}, **opts))
    record("冷启动", f"{took:.1f} 秒，{sbx.sandbox_id}")
    try:
        sbx = probe(sbx, opts)
    finally:
        killed = Sandbox.kill(sbx.sandbox_id, **opts)
        left = [s.sandbox_id for s in Sandbox.list(**opts).next_items() if s.sandbox_id == sbx.sandbox_id]
        record("删除", "已删" if killed and not left else f"没删掉，到控制台手动删 {sbx.sandbox_id}")

    print("\n结果（贴进 docs/deploy-aliyun-sg.md 第 8.6 节）：")
    for item, result in rows:
        print(f"- {item}：{result}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # noqa: BLE001 —— 一行说清楚哪里错了
        print(f"[失败] {type(err).__name__}: {str(err).splitlines()[0][:300] if str(err) else ''}")
        sys.exit(1)

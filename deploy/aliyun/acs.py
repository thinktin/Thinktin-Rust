"""ACS 容器版沙箱的集群准备（docs/handoff.md 第 4 节）。

分两部分：

- **OpenAPI 部分**（走 443，云端会话里能跑）：找集群，看、装沙箱组件。
    deploy/aliyun/run.sh acs                          只读：找集群，看沙箱组件装没装、配置项、要花多少
    deploy/aliyun/run.sh acs --addons                 只打印要装的组件、配置（Key 打码）和费用估算
    deploy/aliyun/run.sh acs --addons --apply         装 ack-agent-sandbox-controller、ack-sandbox-manager
- **kubectl 部分**（连集群的 API Server）：**只能在集群 VPC 里的机器上跑**。云端会话的出网代理只放行 443 端口的 HTTPS，
  API Server 在 6443、要客户端证书，port-forward 要 WebSocket，这三样代理都不支持（/root/.ccr/README.md），给 API Server
  绑公网 EIP 也没用。
    deploy/aliyun/run.sh acs --pool [--apply]         内网 kubeconfig、kubectl，建预热池 SandboxSet code-interpreter（1 个沙箱）
    deploy/aliyun/run.sh acs --pool-delete [--apply]  删掉预热池

装组件和预热池都**一直在收钱**（组件的容器、池子里的沙箱）：先列费用，用户同意了再加 --apply。

生成的东西都在 target/ 下（.gitignore 忽略），不打印：
- target/aliyun-acs/sandbox.json：沙箱管理器的 domain、adminApiKey、服务端口，`run.sh sandbox --acs` 读它。丢了（容器回收）就从
  已装组件的配置里读回来，不会换新 Key
- target/aliyun-acs/kubeconfig：集群的内网 kubeconfig（临时的，1 天后失效，重跑本脚本换新的）
- target/aliyun-acs/<组件>.schema.json：组件的配置项
- target/bin/kubectl：钉死版本、核对过 SHA-256 的官方二进制
"""

import argparse
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time

import httpx
from alibabacloud_credentials.client import Client as Credentials
from alibabacloud_cs20151215 import models as cs_models
from alibabacloud_cs20151215.client import Client as Cs
from alibabacloud_tea_openapi import models as openapi

ACS_DIR = "target/aliyun-acs"
KUBECONFIG = f"{ACS_DIR}/kubeconfig"
STATE = f"{ACS_DIR}/sandbox.json"
KUBECTL = "target/bin/kubectl"
# 和集群的 1.36 对得上；dl.k8s.io 上 v1.36.5 的 linux/amd64 二进制（2026-09-23 发布）。
KUBECTL_VERSION = "v1.36.5"
KUBECTL_SHA256 = "33bc88a24c3b09cf55bfd59e6ca977881b61fc3f25ab65bc80c65b430248648e"
KUBECONFIG_MINUTES = 24 * 60

CONTROLLER = "ack-agent-sandbox-controller"
MANAGER = "ack-sandbox-manager"
NAMESPACE = "sandbox-system"
POOL = "code-interpreter"
# 阿里云文档的示例镜像（测试用），换成集群所在地域、走 VPC 地址（没有 NAT 也拉得到）。
IMAGE = "registry-{region}-vpc.ack.aliyuncs.com/acs/code-interpreter:v1.6"
# 测试时组件每个容器的资源（默认是 2 核 4G，测试用不了那么多）。
TEST_CPU, TEST_MEMORY = "0.5", "1Gi"
# 海外通用算力的单价（部署文档第 2 节）：每核每小时、每 GB 每小时。
PRICE_CPU_HOUR, PRICE_GIB_HOUR = 0.089, 0.044
HOURS_PER_MONTH = 730


def config(endpoint, region):
    return openapi.Config(credential=Credentials(), endpoint=endpoint, region_id=region)


def in_cloud_session():
    return os.environ.get("CLAUDE_CODE_REMOTE") == "true"


def private_file(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {}


def kubectl(*args, check=True, stdin=None):
    return subprocess.run([KUBECTL, "--kubeconfig", KUBECONFIG, *args], input=stdin, capture_output=True, text=True,
                          check=check)


def ensure_kubectl():
    def ok():
        if not os.path.exists(KUBECTL):
            return False
        with open(KUBECTL, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest() == KUBECTL_SHA256

    if ok():
        return "已有"
    url = f"https://dl.k8s.io/release/{KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    resp = httpx.get(url, follow_redirects=True, timeout=300)
    resp.raise_for_status()
    if hashlib.sha256(resp.content).hexdigest() != KUBECTL_SHA256:
        raise RuntimeError("下载的 kubectl 校验和对不上，没用它")
    os.makedirs(os.path.dirname(KUBECTL), exist_ok=True)
    with open(KUBECTL, "wb") as f:
        f.write(resp.content)
    os.chmod(KUBECTL, 0o755)
    return "已下载并核对"


def find_cluster(cs, region, wanted):
    clusters = cs.describe_clusters_v1(cs_models.DescribeClustersV1Request(region_id=region, page_size=50)).body.clusters or []
    for c in clusters:
        print(f"  {c.name}（{c.cluster_id}，{c.cluster_type}/{c.profile or '-'}，{c.state}，{c.current_version}）")
    if wanted:
        clusters = [c for c in clusters if wanted in (c.name, c.cluster_id)]
    if len(clusters) != 1:
        hint = "用 --cluster 指定名字或 ID" if clusters else "控制台里建好了吗？地域对不对？"
        raise RuntimeError(f"找到 {len(clusters)} 个符合的集群：{hint}")
    return clusters[0]


def endpoints(detail):
    try:
        urls = json.loads(detail.master_url or "{}")
    except ValueError:
        urls = {}
    return urls.get("api_server_endpoint"), urls.get("intranet_api_server_endpoint")


def leaves(schema, path=()):
    """JSON Schema 里每个叶子配置项：(路径, 类型, 默认值)。"""
    props = schema.get("properties") or {}
    if not props:
        yield path, schema.get("type"), schema.get("default")
        return
    for name, sub in props.items():
        yield from leaves(sub or {}, (*path, name))


def defaults(schema):
    """按配置项的默认值拼一份配置。"""
    out = {}
    for path, _, value in leaves(schema):
        if value is None or not path:
            continue
        put(out, path, value)
    return out


def put(cfg, path, value):
    node = cfg
    for key in path[:-1]:
        node = node.setdefault(key, {})
    node[path[-1]] = value


def find_leaf(cfg, name):
    """配置里第一个叫 name（不分大小写）的叶子的值。"""
    if isinstance(cfg, dict):
        for key, value in cfg.items():
            if key.lower() == name.lower() and not isinstance(value, dict):
                return value
            found = find_leaf(value, name)
            if found is not None:
                return found
    return None


def manager_config(schema, domain, api_key):
    """ack-sandbox-manager 的测试配置：默认值上改 domain、adminApiKey，关掉 TLS 和 Ingress，副本减到 1，容器资源调小省钱。
    找不到 domain 或 adminApiKey 这两项就不装（配置项名字变了，先看 schema 再改这里）。"""
    cfg = defaults(schema)
    found = {"domain": False, "adminapikey": False}
    for path, kind, _ in leaves(schema):
        if not path:
            continue
        leaf = path[-1].lower()
        if leaf in found:
            put(cfg, path, domain if leaf == "domain" else api_key)
            found[leaf] = True
        elif kind == "boolean" and ("tls" in leaf or "ingress" in leaf):
            put(cfg, path, False)
        elif leaf == "replicacount" and kind in ("integer", "number"):
            put(cfg, path, 1)
        elif "resources" in (p.lower() for p in path[:-1]) and leaf in ("cpu", "memory"):
            put(cfg, path, TEST_CPU if leaf == "cpu" else TEST_MEMORY)
    missing = [k for k, v in found.items() if not v]
    if missing:
        raise RuntimeError(f"{MANAGER} 的配置项里没找到 {missing}：看 {ACS_DIR}/{MANAGER}.schema.json 再改 manager_config")
    return cfg


def cores(value):
    text = str(value)
    return float(text[:-1]) / 1000 if text.endswith("m") else float(text)


def gib(value):
    m = re.fullmatch(r"([0-9.]+)\s*([KMGT]i?)?", str(value))
    if not m:
        return 0.0
    units = {None: 1 / 2**30, "Ki": 1 / 2**20, "Mi": 1 / 2**10, "Gi": 1, "Ti": 2**10,
             "K": 1e3 / 2**30, "M": 1e6 / 2**30, "G": 1e9 / 2**30, "T": 1e12 / 2**30}
    return float(m.group(1)) * units[m.group(2)]


def estimate(cfg):
    """配置里每组 resources（requests、limits 取大的）加起来的核数、内存和每月费用。副本数没算进去。"""
    total_cpu = total_mem = 0.0

    def walk(node):
        nonlocal total_cpu, total_mem
        if not isinstance(node, dict):
            return
        for key, value in node.items():
            if key.lower() == "resources" and isinstance(value, dict):
                parts = [value.get("requests") or {}, value.get("limits") or {}]
                cpu = max((cores(p["cpu"]) for p in parts if "cpu" in p), default=0)
                mem = max((gib(p["memory"]) for p in parts if "memory" in p), default=0)
                total_cpu, total_mem = total_cpu + cpu, total_mem + mem
            else:
                walk(value)

    walk(cfg)
    monthly = (total_cpu * PRICE_CPU_HOUR + total_mem * PRICE_GIB_HOUR) * HOURS_PER_MONTH
    return total_cpu, total_mem, monthly


def masked(cfg, api_key):
    return json.dumps(cfg, ensure_ascii=False).replace(api_key, "e2b_****")


def wait_task(cs, task_id, what, timeout=900):
    deadline = time.time() + timeout
    while time.time() < deadline:
        body = cs.describe_task_info(task_id).body
        state = (body.state or "").lower()
        if state == "success":
            return
        if state in ("fail", "failed"):
            raise RuntimeError(f"{what} 失败：{body.error.message if body.error else body.state}")
        time.sleep(10)
    raise TimeoutError(f"{what} 等了 {timeout} 秒还没好（任务 {task_id}）")


def install(cs, cluster_id, name, version, cfg, what):
    body = cs_models.InstallClusterAddonsRequestBody(name=name, version=version, config=json.dumps(cfg) if cfg else None)
    resp = cs.install_cluster_addons(cluster_id, cs_models.InstallClusterAddonsRequest(body=[body])).body
    task = getattr(resp, "task_id", None)
    if task:
        wait_task(cs, task, what)


def installed_manager_key(cs, cid):
    """已装的 sandbox-manager 的 adminApiKey 和 domain（从组件配置里读，不打印）。读不到返回 (None, None)。"""
    try:
        cfg = json.loads(cs.get_cluster_addon_instance(cid, MANAGER).body.config or "{}")
    except Exception:  # noqa: BLE001 —— 读不到就让调用方停下
        return None, None
    return find_leaf(cfg, "adminApiKey"), find_leaf(cfg, "domain")


def sandboxset(region, image):
    return json.dumps({
        "apiVersion": "agents.kruise.io/v1alpha1",
        "kind": "SandboxSet",
        "metadata": {"name": POOL, "namespace": "default"},
        "spec": {
            "runtimes": [{"name": "csi"}, {"name": "agent-runtime"}],
            "replicas": 1,
            "template": {
                "metadata": {"labels": {
                    "alibabacloud.com/acs": "true",
                    "alibabacloud.com/compute-class": "agent-sandbox",
                    "alibabacloud.com/compute-qos": "default",
                }},
                "spec": {
                    "automountServiceAccountToken": False,
                    "containers": [{
                        "name": "sandbox",
                        "image": image or IMAGE.format(region=region),
                        "imagePullPolicy": "IfNotPresent",
                        "resources": {
                            "limits": {"cpu": "1", "memory": "1Gi"},
                            "requests": {"cpu": "1", "memory": "1Gi", "ephemeral-storage": "30Gi"},
                        },
                    }],
                    "terminationGracePeriodSeconds": 30,
                },
            },
        },
    })


def addons(cs, cid, region, args):
    installed = {a.name: a for a in (cs.list_cluster_addon_instances(cid).body.addons or [])}
    schemas = {}
    print("\n沙箱组件：")
    for name in (CONTROLLER, MANAGER):
        meta = cs.describe_addon(name, cs_models.DescribeAddonRequest(cluster_id=cid, region_id=region)).body
        schema = json.loads(meta.config_schema or "{}")
        schemas[name] = (meta.version, schema)
        private_file(f"{ACS_DIR}/{name}.schema.json", json.dumps(schema, ensure_ascii=False, indent=2))
        have = installed.get(name)
        state = f"已装 {have.version}（{have.state}）" if have else "没装"
        fields = ", ".join(".".join(p) for p, _, _ in leaves(schema) if p) or "无"
        print(f"  {name}：{state}，可装 {meta.version}\n    配置项：{fields}")
    if not args.addons:
        return 0

    state = load_state()
    if MANAGER in installed:
        # 已经装了：Key 以组件里的为准（sandbox.json 可能随容器回收丢了），不生成新的。
        key, domain = installed_manager_key(cs, cid)
        if not key:
            print(f"[不通过] {MANAGER} 已经装了，但读不到它的 adminApiKey。要换 Key 只能卸了重装（先问用户）。")
            return 1
        state.update(cluster_id=cid, domain=domain or args.domain, api_key=key)
        api_key = key
    else:
        api_key = state.get("api_key") if state.get("cluster_id") == cid else None
        api_key = api_key or "e2b_" + secrets.token_hex(20)
    todo = [n for n in (CONTROLLER, MANAGER) if n not in installed]
    controller_cfg = defaults(schemas[CONTROLLER][1])
    manager_cfg = manager_config(schemas[MANAGER][1], args.domain, api_key) if MANAGER in todo else None
    if not todo:
        print("\n两个组件都装好了。")
    else:
        print("\n要装：")
        cpu = mem = monthly = 0.0
        for name, cfg in ((CONTROLLER, controller_cfg), (MANAGER, manager_cfg)):
            if name not in todo:
                continue
            c, m, y = estimate(cfg)
            cpu, mem, monthly = cpu + c, mem + m, monthly + y
            shown = masked(cfg, api_key) if cfg is manager_cfg else json.dumps(cfg, ensure_ascii=False)
            print(f"  {name} {schemas[name][0]}：配置 {shown}")
        print(f"  费用估算：配置里写明的资源约 {cpu:g} 核 {mem:g}G，每月约 ¥{monthly:.0f}（海外通用算力价；没写资源的容器、"
              "副本数、控制器自带的容器没算进去，装完用 ACS 控制台的费用核对）")
        if not args.apply:
            print("组件的容器装上就一直在收钱：用户同意了再加 --apply。")
            return 0
        if CONTROLLER in todo:
            print(f"装 {CONTROLLER}……（第一次装要在控制台授权 AliyunCSManagedAgentSandboxRole，失败的话请用户去点）")
            install(cs, cid, CONTROLLER, schemas[CONTROLLER][0], None, CONTROLLER)
        if MANAGER in todo:
            print(f"装 {MANAGER}……")
            install(cs, cid, MANAGER, schemas[MANAGER][0], manager_cfg, MANAGER)
            state.update(cluster_id=cid, domain=args.domain, api_key=api_key)
    private_file(STATE, json.dumps(state))
    print(f"sandbox-manager 的 domain 和 Key 存在 {STATE}（不显示）。")
    return 0


def pool(cid, region, cs, args):
    if in_cloud_session():
        print("\n[不通过] 预热池要用 kubectl 连集群的 API Server，云端会话连不上（代理只放行 443，API Server 在 6443、"
              "要客户端证书）。要在集群 VPC 里的机器上跑这一步，见 docs/handoff.md。")
        return 1
    kubeconfig = cs.describe_cluster_user_kubeconfig(
        cid, cs_models.DescribeClusterUserKubeconfigRequest(private_ip_address=True, temporary_duration_minutes=KUBECONFIG_MINUTES)
    ).body.config
    private_file(KUBECONFIG, kubeconfig)
    print(f"\n  kubeconfig（内网）：已存 {KUBECONFIG}（{KUBECONFIG_MINUTES // 60} 小时后失效，不显示）")
    print(f"  kubectl {KUBECTL_VERSION}：{ensure_kubectl()}")
    probe = kubectl("get", "sandboxsets", "-n", "default", "-o", "name", check=False)
    if probe.returncode != 0:
        err = probe.stderr.strip()
        if "Forbidden" in err or "forbidden" in err:
            print("[不通过] 子账号在集群里没权限：请用户到 ACS 控制台 → 授权管理 → RAM 用户 thinktin-deploy → 选这个集群、"
                  "所有命名空间、管理员。")
        else:
            print(f"[不通过] 连不上集群：{err[:200]}")
        return 1

    if args.pool_delete:
        if not args.apply:
            print(f"只读：没删。加 --apply 才真的删预热池 {POOL}（删了就不再收池子里沙箱的钱）。")
            return 0
        out = kubectl("delete", "sandboxset", POOL, "-n", "default", "--ignore-not-found", check=False)
        print(out.stdout.strip() or out.stderr.strip() or f"预热池 {POOL} 不在了")
        return 0 if out.returncode == 0 else 1

    manifest = sandboxset(region, args.image)
    image = json.loads(manifest)["spec"]["template"]["spec"]["containers"][0]["image"]
    print(f"\n预热池 {POOL}：1 个沙箱（1 核 1G），镜像 {image}")
    if not args.apply:
        monthly = (PRICE_CPU_HOUR + PRICE_GIB_HOUR) * HOURS_PER_MONTH
        print(f"池子里的沙箱一直在跑，每月约 ¥{monthly:.0f}（按 1 核 1G 的通用算力价估，沙箱实例另有单价）：用户同意了再加 --apply。")
        return 0
    applied = kubectl("apply", "-f", "-", check=False, stdin=manifest)
    if applied.returncode != 0:
        print(f"[不通过] 建预热池失败：{applied.stderr.strip()[:300]}")
        return 1
    print(applied.stdout.strip())
    template = ("{range .items[*]}{.metadata.name} {.status.phase} "
                "{.status.initContainerStatuses[*].state.waiting.reason} "
                "{.status.containerStatuses[*].state.waiting.reason}{'\\n'}{end}")
    for _ in range(30):
        lines = [line for line in kubectl("get", "pods", "-n", "default", "-o", f"jsonpath={template}", check=False)
                 .stdout.splitlines() if line.startswith(POOL)]
        print(f"  {'；'.join(lines) or '还没有沙箱'}")
        if any("ErrImagePull" in line or "ImagePullBackOff" in line for line in lines):
            print("[不通过] 拉不下镜像：没有 NAT 出不去。先试 ACR 的 VPC 地址（--image）；预热池还在、可能在收钱，"
                  "不测了就 `run.sh acs --pool-delete --apply`。")
            return 1
        if any(line.split()[1:2] == ["Running"] for line in lines):
            print(f"[通过] 预热池有 1 个沙箱在跑：{kubectl('get', 'sandboxset', POOL, '-n', 'default', check=False).stdout.strip()}")
            return 0
        time.sleep(10)
    print("[不通过] 预热池 5 分钟没就绪（最后的状态见上）。预热池还在、可能在收钱：不测了就 `run.sh acs --pool-delete --apply`。")
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--cluster", help="集群名字或 ID（地域里只有一个集群时不用填）")
    parser.add_argument("--addons", action="store_true", help="装沙箱组件（OpenAPI，云端会话能跑）")
    parser.add_argument("--pool", action="store_true", help="建预热池（kubectl，只能在集群 VPC 里跑）")
    parser.add_argument("--pool-delete", action="store_true", help="删预热池（kubectl，只能在集群 VPC 里跑）")
    parser.add_argument("--domain", default="localhost", help="沙箱管理器的 domain；port-forward 测试用 localhost")
    parser.add_argument("--image", help="预热池的镜像（默认阿里云文档的 code-interpreter 示例镜像，走 VPC 地址）")
    parser.add_argument("--apply", action="store_true", help="真的装、真的建（要收费，先问用户）")
    args = parser.parse_args()
    region = args.region
    cs = Cs(config(f"cs.{region}.aliyuncs.com", region))

    print(f"地域 {region} 的集群：")
    cluster = find_cluster(cs, region, args.cluster)
    cid = cluster.cluster_id
    detail = cs.describe_cluster_detail(cid).body
    public, private = endpoints(detail)
    print(f"\n用 {detail.name}（{cid}），{detail.state}，K8s {detail.current_version}，VPC {detail.vpc_id}")
    print(f"  API Server 内网：{private or '-'}；公网：{public or '没开'}（云端会话用不上公网的，kubectl 要在 VPC 里跑）")

    code = addons(cs, cid, region, args)
    if code or not (args.pool or args.pool_delete):
        return code
    return pool(cid, region, cs, args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # noqa: BLE001 —— 一行说清楚哪里错了
        code = getattr(err, "code", None)
        message = getattr(err, "message", None) or str(err)
        print(f"[失败] {code or type(err).__name__}: {message.splitlines()[0][:300] if message else ''}")
        sys.exit(1)

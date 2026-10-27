"""ACS 容器版沙箱的集群准备（docs/handoff.md 第 4 节第 2–4 步）。

    deploy/aliyun/run.sh acs                          只读：找集群，存公网 kubeconfig、装 kubectl，看沙箱组件装没装、配置项长什么样
    deploy/aliyun/run.sh acs --addons                 只打印要装的组件和配置（Key 打码）
    deploy/aliyun/run.sh acs --addons --apply         装 ack-agent-sandbox-controller、ack-sandbox-manager
    deploy/aliyun/run.sh acs --pool [--apply]         预热池 SandboxSet code-interpreter（1 个沙箱）
    deploy/aliyun/run.sh acs --pool-delete --apply    删掉预热池

装组件和预热池都**一直在收钱**（组件的容器、池子里的沙箱）：先按 ACS 的价格列费用，用户同意了再加 --apply。

生成的东西都在 target/ 下（.gitignore 忽略），不打印：
- target/aliyun-acs/kubeconfig：集群的公网 kubeconfig（临时的，1 天后失效，重跑本脚本换新的）
- target/aliyun-acs/sandbox.json：沙箱管理器的 domain、adminApiKey、服务端口，`run.sh sandbox --acs` 读它
- target/aliyun-acs/<组件>.schema.json：组件的配置项
- target/bin/kubectl：钉死版本、核对过 SHA-256 的官方二进制
"""

import argparse
import hashlib
import json
import os
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


def config(endpoint, region):
    return openapi.Config(credential=Credentials(), endpoint=endpoint, region_id=region)


def private_file(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def kubectl(*args, check=True):
    return subprocess.run([KUBECTL, "--kubeconfig", KUBECONFIG, *args], capture_output=True, text=True, check=check)


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
        node = out
        for key in path[:-1]:
            node = node.setdefault(key, {})
        node[path[-1]] = value
    return out


def put(cfg, path, value):
    node = cfg
    for key in path[:-1]:
        node = node.setdefault(key, {})
    node[path[-1]] = value


def manager_config(schema, domain, api_key):
    """ack-sandbox-manager 的测试配置：默认值上改 domain、adminApiKey，关掉 TLS 和 Ingress，副本减到 1 省钱。
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
    missing = [k for k, v in found.items() if not v]
    if missing:
        raise RuntimeError(f"{MANAGER} 的配置项里没找到 {missing}：看 {ACS_DIR}/{MANAGER}.schema.json 再改 manager_config")
    return cfg


def masked(cfg, api_key):
    return json.dumps(cfg, ensure_ascii=False).replace(api_key, "e2b_****")


def wait_task(cs, task_id, what, timeout=900):
    deadline = time.time() + timeout
    while time.time() < deadline:
        body = cs.describe_task_info(task_id).body
        if body.state in ("success", "Success"):
            return
        if body.state in ("fail", "failed", "Failed"):
            raise RuntimeError(f"{what} 失败：{body.error}")
        time.sleep(10)
    raise TimeoutError(f"{what} 等了 {timeout} 秒还没好（任务 {task_id}）")


def install(cs, cluster_id, name, version, cfg, what):
    body = cs_models.InstallClusterAddonsRequestBody(name=name, version=version, config=json.dumps(cfg) if cfg else None)
    resp = cs.install_cluster_addons(cluster_id, cs_models.InstallClusterAddonsRequest(body=[body])).body
    task = getattr(resp, "task_id", None)
    if task:
        wait_task(cs, task, what)


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


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--cluster", help="集群名字或 ID（地域里只有一个集群时不用填）")
    parser.add_argument("--addons", action="store_true", help="装沙箱组件")
    parser.add_argument("--pool", action="store_true", help="建预热池（1 个沙箱）")
    parser.add_argument("--pool-delete", action="store_true", help="删预热池")
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
    print(f"  API Server 公网：{public or '没开'}；内网：{private or '-'}")
    if not public:
        print("[不通过] API Server 没开公网：控制台 → 集群信息 → 基本信息里给 API Server 绑 EIP（按流量计费，先问用户），"
              "云端会话才连得上。")
        return 1

    kubeconfig = cs.describe_cluster_user_kubeconfig(
        cid, cs_models.DescribeClusterUserKubeconfigRequest(private_ip_address=False, temporary_duration_minutes=KUBECONFIG_MINUTES)
    ).body.config
    private_file(KUBECONFIG, kubeconfig)
    print(f"  kubeconfig：已存 {KUBECONFIG}（{KUBECONFIG_MINUTES // 60} 小时后失效，不显示）")
    print(f"  kubectl {KUBECTL_VERSION}：{ensure_kubectl()}")
    nodes = kubectl("get", "nodes", "-o", "name", check=False)
    print(f"  连集群：{'通' if nodes.returncode == 0 else '不通：' + nodes.stderr.strip()[:200]}")
    if nodes.returncode != 0:
        return 1

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

    state = load_state()
    if args.addons:
        api_key = state.get("api_key") or "e2b_" + secrets.token_hex(20)
        cfg = manager_config(schemas[MANAGER][1], args.domain, api_key)
        print(f"\n要装：{CONTROLLER} {schemas[CONTROLLER][0]}（默认配置）；{MANAGER} {schemas[MANAGER][0]}，配置 {masked(cfg, api_key)}")
        if not args.apply:
            print("组件的容器装上就一直在收钱：先列费用、用户同意了再加 --apply。")
            return 0
        state.update(cluster_id=cid, domain=args.domain, api_key=api_key)
        private_file(STATE, json.dumps(state))
        if CONTROLLER not in installed:
            print(f"装 {CONTROLLER}……（第一次装要在控制台授权 AliyunCSManagedAgentSandboxRole，失败的话请用户去点）")
            install(cs, cid, CONTROLLER, schemas[CONTROLLER][0], None, CONTROLLER)
        if MANAGER not in installed:
            print(f"装 {MANAGER}……")
            install(cs, cid, MANAGER, schemas[MANAGER][0], cfg, MANAGER)
        port = kubectl("get", "svc", "sandbox-manager", "-n", NAMESPACE, "-o", "jsonpath={.spec.ports[0].port}").stdout.strip()
        state["service_port"] = int(port or 7788)
        private_file(STATE, json.dumps(state))
        print(f"装好了。sandbox-manager 的服务端口 {state['service_port']}，配置存在 {STATE}（不显示 Key）")

    if args.pool or args.pool_delete:
        if args.pool_delete:
            print(f"\n删预热池 {POOL}")
            if args.apply:
                print(kubectl("delete", "sandboxset", POOL, "-n", "default", "--ignore-not-found").stdout.strip() or "已删")
            return 0
        manifest = sandboxset(region, args.image)
        print(f"\n预热池 {POOL}：1 个沙箱（1 核 1G），镜像 {json.loads(manifest)['spec']['template']['spec']['containers'][0]['image']}")
        if not args.apply:
            print("池子里的沙箱一直在收钱：先列费用、用户同意了再加 --apply。")
            return 0
        applied = subprocess.run([KUBECTL, "--kubeconfig", KUBECONFIG, "apply", "-f", "-"], input=manifest,
                                 capture_output=True, text=True)
        print(applied.stdout.strip() or applied.stderr.strip())
        for _ in range(30):
            pods = kubectl("get", "pods", "-n", "default", "-o",
                           "jsonpath={range .items[*]}{.metadata.name} {.status.phase} "
                           "{.status.containerStatuses[0].state.waiting.reason}{'\\n'}{end}", check=False).stdout.strip()
            print(f"  {pods or '还没有沙箱'}")
            if "ErrImagePull" in pods or "ImagePullBackOff" in pods:
                print("[不通过] 拉不下镜像：没有 NAT 出不去。先试 ACR 的 VPC 地址（--image），不行再列 NAT 网关的费用请用户确认。")
                return 1
            if " Running" in pods:
                break
            time.sleep(10)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # noqa: BLE001 —— 一行说清楚哪里错了
        code = getattr(err, "code", None)
        message = getattr(err, "message", None) or str(err)
        print(f"[失败] {code or type(err).__name__}: {message.splitlines()[0][:300] if message else ''}")
        sys.exit(1)

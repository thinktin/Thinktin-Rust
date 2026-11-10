"""第 2 阶段的服务机（docs/deploy-aliyun-sg.md 第 4 节、第 8.9 节）：建一台 ECS，用云助手在上面跑命令、传文件。

服务机放在 ACS 集群的 VPC 里（`run.sh network` 建的交换机 `thinktin-svc-a`、安全组 `thinktin-svc`）：平台的四个服务、Postgres
以后都在它上面；沙箱实测要的 kubectl 也只能在这个 VPC 里跑（云端会话连不上集群的 API Server）。不开 22、不设密码、不放密钥对：
只用云助手（RunCommand，走 443 的 OpenAPI）操作。

默认只打印计划和价钱，加 --apply 才下单（**要收费，先问用户**）。按名字 `thinktin-svc` 找已有的机器，重跑不会重复买。

    deploy/aliyun/run.sh ecs                              看有没有、要买什么、多少钱
    deploy/aliyun/run.sh ecs --apply                      买（按量付费）
    deploy/aliyun/run.sh ecs --run 'uname -a'             在机器上跑一条命令（root），打印输出和退出码
    deploy/aliyun/run.sh ecs --run-file path/to/script.sh 跑本地的一个脚本文件
    deploy/aliyun/run.sh ecs --push deploy/aliyun /opt/thinktin/deploy/aliyun   把本地文件或目录传上去（打包、分块、核对 SHA-256）
    deploy/aliyun/run.sh ecs --release --apply            退掉这台机器（盘和公网地址一起释放，数据就没了）

云助手一次命令的脚本最多约 24 KB（Base64 以后），输出最多返回约 24 KB：传大文件用 --push（分块），长输出让命令自己写到文件里再分段看。
"""

import argparse
import base64
import concurrent.futures
import hashlib
import io
import os
import sys
import tarfile
import time

from alibabacloud_credentials.client import Client as Credentials
from alibabacloud_ecs20140526 import models as m
from alibabacloud_ecs20140526.client import Client as Ecs
from alibabacloud_tea_openapi import models as openapi

NAME = "thinktin-svc"
VSWITCH = "thinktin-svc-a"
SECURITY_GROUP = "thinktin-svc"
# 10 个测试用户的省钱方案（部署文档第 8.9 节）：2 核 4G 的经济型。
INSTANCE_TYPE = "ecs.e-c1m2.large"
SYSTEM_DISK = ("cloud_essd_entry", 40)
# 数据盘放 Postgres。
DATA_DISK = ("cloud_essd_entry", 20)
# 公网按流量计费，上限 10 Mbps（上限不收钱，只是封顶）。
BANDWIDTH_OUT = 10
IMAGE_PATTERN = "ubuntu_24_04_x64*"
# 一块最多这么大：云助手一条命令的脚本最多 18 KB（Base64 以后 24 KB；原样发也是 18 KB）。块自己编成 Base64 是
# 17.8 KB，加上外面几行脚本刚好放得下（脚本原样发，不再编一层）。
CHUNK = 13 * 1024
# 同时传几块（每块写成单独的编号文件，最后按顺序拼起来）。
PARALLEL = 4


def config(endpoint, region):
    return openapi.Config(credential=Credentials(), endpoint=endpoint, region_id=region)


def find_instance(ecs, region):
    body = ecs.describe_instances(m.DescribeInstancesRequest(region_id=region, instance_name=NAME, page_size=10)).body
    found = [i for i in (body.instances.instance if body.instances else []) or [] if i.instance_name == NAME]
    if len(found) > 1:
        raise RuntimeError(f"有 {len(found)} 台叫 {NAME} 的机器，先在控制台看是怎么回事")
    return found[0] if found else None


def addresses(inst):
    private = (inst.vpc_attributes.private_ip_address.ip_address if inst.vpc_attributes else []) or []
    public = (inst.public_ip_address.ip_address if inst.public_ip_address else []) or []
    return (private[0] if private else "-"), (public[0] if public else "-")


def placement(ecs, region):
    """交换机、安全组（按名字，run.sh network 建的）和最新的 Ubuntu 24.04 镜像。"""
    vsw = ecs.describe_vswitches(m.DescribeVSwitchesRequest(region_id=region, page_size=50)).body
    vswitches = [v for v in (vsw.v_switches.v_switch if vsw.v_switches else []) or [] if v.v_switch_name == VSWITCH]
    if len(vswitches) != 1:
        raise RuntimeError(f"要正好一个叫 {VSWITCH} 的交换机，现在有 {len(vswitches)} 个：先跑 run.sh network --apply")
    sgs = ecs.describe_security_groups(
        m.DescribeSecurityGroupsRequest(region_id=region, vpc_id=vswitches[0].vpc_id, security_group_name=SECURITY_GROUP)
    ).body
    groups = (sgs.security_groups.security_group if sgs.security_groups else []) or []
    if len(groups) != 1:
        raise RuntimeError(f"要正好一个叫 {SECURITY_GROUP} 的安全组，现在有 {len(groups)} 个：先跑 run.sh network --apply")
    images = ecs.describe_images(
        m.DescribeImagesRequest(
            region_id=region, image_owner_alias="system", image_name=IMAGE_PATTERN, ostype="linux",
            architecture="x86_64", status="Available", page_size=50,
        )
    ).body
    listed = sorted((images.images.image if images.images else []) or [], key=lambda i: i.creation_time or "", reverse=True)
    if not listed:
        raise RuntimeError(f"地域里没有名字是 {IMAGE_PATTERN} 的公共镜像")
    return vswitches[0], groups[0], listed[0]


def price(ecs, region, instance_type):
    p = ecs.describe_price(
        m.DescribePriceRequest(
            region_id=region, resource_type="instance", instance_type=instance_type, price_unit="Hour",
            system_disk=m.DescribePriceRequestSystemDisk(category=SYSTEM_DISK[0], size=SYSTEM_DISK[1]),
            data_disk=[m.DescribePriceRequestDataDisk(category=DATA_DISK[0], size=DATA_DISK[1])],
            internet_charge_type="PayByTraffic", internet_max_bandwidth_out=BANDWIDTH_OUT, instance_network_type="vpc",
        )
    ).body.price_info.price
    return float(p.trade_price), p.currency


def run_request(region, instance_type, vswitch, group, image, dry_run):
    return m.RunInstancesRequest(
        region_id=region, zone_id=vswitch.zone_id, image_id=image.image_id, instance_type=instance_type,
        security_group_id=group.security_group_id, v_switch_id=vswitch.v_switch_id,
        instance_name=NAME, host_name=NAME, description="ThinkTin 服务机（deploy/aliyun/ecs.py）",
        instance_charge_type="PostPaid", spot_strategy="NoSpot", amount=1,
        internet_charge_type="PayByTraffic", internet_max_bandwidth_out=BANDWIDTH_OUT,
        system_disk=m.RunInstancesRequestSystemDisk(category=SYSTEM_DISK[0], size=str(SYSTEM_DISK[1])),
        data_disk=[m.RunInstancesRequestDataDisk(category=DATA_DISK[0], size=DATA_DISK[1], delete_with_instance=True)],
        security_enhancement_strategy="Active",
        tag=[m.RunInstancesRequestTag(key="thinktin", value="svc")],
        dry_run=dry_run,
    )


def create(ecs, region, args):
    vswitch, group, image = placement(ecs, region)
    hourly, currency = price(ecs, region, args.type)
    print(f"[要买] 服务机 {NAME}：{args.type}，{vswitch.zone_id}，交换机 {vswitch.v_switch_id}，安全组 {group.security_group_id}")
    print(f"       镜像 {image.image_name}；系统盘 {SYSTEM_DISK[1]}G、数据盘 {DATA_DISK[1]}G（{SYSTEM_DISK[0]}）；"
          f"公网按流量、上限 {BANDWIDTH_OUT} Mbps；不开 22、没有密码和密钥对，只用云助手")
    print(f"       按量付费：每小时 {hourly:.4f} {currency}，一天约 {hourly * 24:.2f}，一个月约 {hourly * 24 * 30:.0f}（流量另算）")
    try:
        ecs.run_instances(run_request(region, args.type, vswitch, group, image, dry_run=True))
    except Exception as err:  # noqa: BLE001 —— 预检通过时接口也是用错误码回的
        if getattr(err, "code", None) != "DryRunOperation":
            raise
        print("       预检通过（参数、库存、余额都行）")
    if not args.apply:
        print("机器开着就一直在收钱：用户同意了再加 --apply。")
        return 0
    ids = ecs.run_instances(run_request(region, args.type, vswitch, group, image, dry_run=False)).body.instance_id_sets.instance_id_set
    print(f"[已下单] {ids[0]}，等它开机……")
    deadline = time.time() + 300
    while time.time() < deadline:
        inst = find_instance(ecs, region)
        if inst and inst.status == "Running":
            private, public = addresses(inst)
            print(f"[已建] 服务机 {NAME} {inst.instance_id}：内网 {private}，公网 {public}")
            return 0
        time.sleep(5)
    print("[不通过] 5 分钟还没开机，去控制台看看；机器已经在收钱了")
    return 1


def invoke(ecs, region, instance_id, script, timeout, plain=False):
    """跑一段脚本（root），等它结束。返回（退出码，输出）。`plain`：脚本原样发（只有 ASCII 时用，省一层 Base64：
    云助手限制的是发过去的内容 24 KB，传文件的块自己已经是 Base64 了，再编一层只能放 12 KB）。"""
    content, encoding = (script, "PlainText") if plain else (base64.b64encode(script.encode()).decode(), "Base64")
    invoke_id = ecs.run_command(
        m.RunCommandRequest(
            region_id=region, type="RunShellScript", command_content=content, content_encoding=encoding,
            instance_id=[instance_id], timeout=timeout, name="thinktin-deploy",
        )
    ).body.invoke_id
    deadline = time.time() + timeout + 60
    while time.time() < deadline:
        time.sleep(2)
        body = ecs.describe_invocation_results(
            m.DescribeInvocationResultsRequest(region_id=region, invoke_id=invoke_id, instance_id=instance_id, content_encoding="PlainText")
        ).body
        results = (body.invocation.invocation_results.invocation_result if body.invocation and body.invocation.invocation_results else []) or []
        if not results:
            continue
        r = results[0]
        if r.invoke_record_status == "Running":
            continue
        output = r.output or ""
        if r.invocation_status != "Success" and r.error_info:
            output += f"\n[云助手] {r.invocation_status}：{r.error_code} {r.error_info}"
        return (r.exit_code if r.exit_code is not None else 1), output
    return 124, f"[云助手] 等了 {timeout + 60} 秒还没结束（invoke {invoke_id}）"


def bundle(path):
    """本地的文件或目录打成 tar.xz（去掉缓存、时间和属主，同样的内容得到同样的包；xz 压二进制比 gzip 小三成）。"""
    buf = io.BytesIO()
    base = os.path.basename(os.path.normpath(path))

    def clean(info):
        if "__pycache__" in info.name or info.name.endswith(".pyc"):
            return None
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = 0
        return info

    with tarfile.open(fileobj=buf, mode="w:xz", preset=9) as tar:
        tar.add(path, arcname=base, filter=clean)
    return base, buf.getvalue()


def push(ecs, region, instance_id, local, remote):
    """把本地的文件或目录放到机器上的 `remote`（它的上一级目录下解包，原来同名的换掉）。"""
    if not remote.startswith("/") or any(c in remote for c in " '\"$`\\;&|<>"):
        raise RuntimeError("远端路径要是不带空格和特殊字符的绝对路径")
    base, data = bundle(local)
    if os.path.basename(remote) != base:
        raise RuntimeError(f"远端路径的最后一段要和本地的名字一样（{base}）")
    digest = hashlib.sha256(data).hexdigest()
    part = f"/tmp/thinktin-push-{digest[:16]}.txz"
    parent = os.path.dirname(remote)
    code, out = invoke(ecs, region, instance_id, f"set -e\nrm -f {part} {part}.[0-9]*\nmkdir -p {parent}\n", 60)
    if code:
        raise RuntimeError(f"准备目录失败：{out.strip()[:200]}")
    chunks = [data[i : i + CHUNK] for i in range(0, len(data), CHUNK)]

    def send(item):
        n, chunk = item
        body = base64.b64encode(chunk).decode()
        script = f"set -e\nbase64 -d > {part}.{n:05d} <<'THINKTIN_EOF'\n{body}\nTHINKTIN_EOF\n"
        last = ""
        for _ in range(3):  # 接口偶尔断一下（连接被重置），重发同一块没有副作用
            try:
                code, out = invoke(ecs, region, instance_id, script, 60, plain=True)
            except Exception as err:  # noqa: BLE001
                last = str(err)[:200]
                time.sleep(2)
                continue
            if code == 0:
                return
            last = out.strip()[:200]
        raise RuntimeError(f"第 {n}/{len(chunks)} 块没传上去：{last}")

    with concurrent.futures.ThreadPoolExecutor(PARALLEL) as pool_:
        list(pool_.map(send, enumerate(chunks, 1)))
    script = (
        f"set -e\ncat {part}.[0-9]* > {part}\nrm -f {part}.[0-9]*\n"
        f"echo '{digest}  {part}' | sha256sum -c - >/dev/null\n"
        f"rm -rf {remote}\ntar -xJf {part} -C {parent}\nrm -f {part}\necho ok\n"
    )
    code, out = invoke(ecs, region, instance_id, script, 120)
    if code:
        raise RuntimeError(f"核对或解包失败：{out.strip()[:200]}")
    print(f"[已传] {local} → {remote}（{len(data)} 字节，{len(chunks)} 块，SHA-256 核对过）")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--type", default=INSTANCE_TYPE, help="机器规格")
    parser.add_argument("--run", help="在机器上跑这条命令（root）")
    parser.add_argument("--run-file", help="在机器上跑本地的这个脚本文件（root）")
    parser.add_argument("--push", nargs=2, metavar=("LOCAL", "REMOTE"), help="把本地文件或目录传到机器上")
    parser.add_argument("--timeout", type=int, default=600, help="--run 最多等多少秒")
    parser.add_argument("--release", action="store_true", help="退掉这台机器（要加 --apply）")
    parser.add_argument("--apply", action="store_true", help="真的买、真的退（买要收费，先问用户）")
    args = parser.parse_args()
    region = args.region
    ecs = Ecs(config(f"ecs.{region}.aliyuncs.com", region))
    inst = find_instance(ecs, region)

    if args.run or args.run_file or args.push:
        if not inst or inst.status != "Running":
            raise RuntimeError(f"服务机 {NAME} 不在或者没开机：先跑 run.sh ecs")
        if args.push:
            return push(ecs, region, inst.instance_id, *args.push)
        script = args.run if args.run else open(args.run_file, encoding="utf-8").read()
        code, out = invoke(ecs, region, inst.instance_id, script, args.timeout)
        print(out.rstrip("\n"))
        print(f"[退出码 {code}]")
        return 0 if code == 0 else 1

    if args.release:
        if not inst:
            print(f"没有叫 {NAME} 的机器。")
            return 0
        private, public = addresses(inst)
        print(f"[要退] 服务机 {NAME} {inst.instance_id}（{inst.status}，内网 {private}，公网 {public}）：盘和公网地址一起释放，上面的数据就没了")
        if not args.apply:
            print("确认要退再加 --apply。")
            return 0
        ecs.delete_instance(m.DeleteInstanceRequest(instance_id=inst.instance_id, force=True))
        print("[已退]")
        return 0

    if inst:
        private, public = addresses(inst)
        hourly, currency = price(ecs, region, inst.instance_type)
        print(f"[已有] 服务机 {NAME} {inst.instance_id}：{inst.instance_type}，{inst.status}，{inst.zone_id}，内网 {private}，公网 {public}")
        print(f"       {inst.instance_charge_type}，每小时约 {hourly:.4f} {currency}（流量另算）")
        return 0
    return create(ecs, region, args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # noqa: BLE001 —— 一行说清楚哪里错了
        code = getattr(err, "code", None) or type(err).__name__
        message = (getattr(err, "message", None) or str(err)).splitlines()[0][:300]
        print(f"[失败] {code}: {message}")
        sys.exit(1)

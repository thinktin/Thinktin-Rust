"""第 1 阶段：网络（docs/deploy-aliyun-sg.md 第 4 节）。都是不收费的资源：交换机、服务机的安全组，没有集群时再加 VPC。

默认只打印计划，加 --apply 才创建。按名字找已有的资源，重跑不会重复建。

    deploy/aliyun/run.sh network                         看要建什么（默认东京）
    deploy/aliyun/run.sh network --apply                 建
    deploy/aliyun/run.sh network --vpc-id vpc-xxx        用指定的 VPC

用哪个 VPC：--vpc-id 指定的 > 地域里 ACS 集群的 VPC（只有一个集群时）> 自己建 `thinktin-<地域>`（10.10.0.0/16）。
服务机、数据库和沙箱要在同一个 VPC 里（沙箱只连服务机上的模型网关），所以有集群就用集群的 VPC：

- 交换机 `thinktin-svc-a`（服务机和数据库）：用集群的 VPC 时在它的网段里挑一个没用过的 /24；自己建的 VPC 用 10.10.1.0/24。
  自己建的 VPC 还加一个 `thinktin-sbx-a`（10.10.16.0/20，agent 沙箱）；ACS 集群有自己的交换机，不用再建
- 安全组 `thinktin-svc`：入方向只开 80、443（HTTPS 和证书验证），不开 22（服务机用云助手操作）
"""

import argparse
import ipaddress
import sys
import time

from alibabacloud_credentials.client import Client as Credentials
from alibabacloud_cs20151215 import models as cs_models
from alibabacloud_cs20151215.client import Client as Cs
from alibabacloud_ecs20140526 import models as ecs_models
from alibabacloud_ecs20140526.client import Client as Ecs
from alibabacloud_tea_openapi import models as openapi
from alibabacloud_vpc20160428 import models as vpc_models
from alibabacloud_vpc20160428.client import Client as Vpc

VPC_NAME = "thinktin-{region}"
VPC_CIDR = "10.10.0.0/16"
# 新加坡 10-27 已经建过的那一套叫 thinktin-sg（ID 见部署文档第 8.6 节）。
LEGACY_NAMES = {"ap-southeast-1": "thinktin-sg"}
SVC_VSWITCH = "thinktin-svc-a"
# 可用区 a：服务机规格、RDS 的 PostgreSQL 16 都有（2026-10-27 检查结果）。
ZONE_SUFFIX = "a"
VSWITCHES = [
    ("thinktin-svc-a", "10.10.1.0/24", "服务机和数据库"),
    ("thinktin-sbx-a", "10.10.16.0/20", "agent 沙箱"),
]
SG_NAME = "thinktin-svc"
SG_RULES = [("80/80", "HTTP：证书验证、跳转 HTTPS"), ("443/443", "HTTPS：接口和中继")]


def config(endpoint, region):
    return openapi.Config(credential=Credentials(), endpoint=endpoint, region_id=region)


def wait(what, fn, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if fn():
            return
        time.sleep(3)
    raise TimeoutError(f"{what} 等了 {timeout} 秒还没就绪")


def free_cidr(vpc, region, existing):
    """在已有 VPC 的网段里挑第一个和现有交换机都不重叠的 /24（已经有 thinktin-svc-a 的话后面会认出来，不再建）。"""
    body = vpc.describe_vswitches(
        vpc_models.DescribeVSwitchesRequest(region_id=region, vpc_id=existing["VpcId"], page_size=50)
    ).body.to_map()
    used = [ipaddress.ip_network(v["CidrBlock"]) for v in body.get("VSwitches", {}).get("VSwitch", []) if v.get("CidrBlock")]
    for block in str(existing.get("CidrBlock", "")).split(","):
        if not block.strip():
            continue
        for net in ipaddress.ip_network(block.strip()).subnets(new_prefix=24):
            if not any(net.overlaps(u) for u in used):
                return str(net)
    raise RuntimeError(f"VPC {existing['VpcId']} 的网段里没有空的 /24 了")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--vpc-id", help="用这个 VPC（默认用地域里 ACS 集群的 VPC）")
    parser.add_argument("--apply", action="store_true", help="真的创建（默认只打印计划）")
    args = parser.parse_args()
    region, apply = args.region, args.apply
    zone = f"{region}{ZONE_SUFFIX}"
    vpc = Vpc(config(f"vpc.{region}.aliyuncs.com", region))
    ecs = Ecs(config(f"ecs.{region}.aliyuncs.com", region))
    print(f"地域 {region}，可用区 {zone}。{'创建' if apply else '只看计划（加 --apply 才创建）'}\n")
    vpc_name = LEGACY_NAMES.get(region, VPC_NAME.format(region=region))

    def describe_vpc(**filters):
        body = vpc.describe_vpcs(vpc_models.DescribeVpcsRequest(region_id=region, **filters)).body.to_map()
        found = body.get("Vpcs", {}).get("Vpc", [])
        return found[0] if found else None

    def cluster_vpc():
        cs = Cs(config(f"cs.{region}.aliyuncs.com", region))
        clusters = cs.describe_clusters_v1(cs_models.DescribeClustersV1Request(region_id=region, page_size=50)).body.clusters or []
        if len(clusters) > 1:
            raise RuntimeError(f"地域里有 {len(clusters)} 个集群，用 --vpc-id 指定用哪个 VPC")
        return (clusters[0].vpc_id, clusters[0].name) if clusters else (None, None)

    vpc_id, owner = args.vpc_id, "指定的"
    if not vpc_id:
        vpc_id, cluster = cluster_vpc()
        owner = f"ACS 集群 {cluster} 的" if vpc_id else None
    if vpc_id:
        existing = describe_vpc(vpc_id=vpc_id)
        if not existing:
            raise RuntimeError(f"找不到 VPC {vpc_id}")
        print(f"[已有] 用{owner} VPC {existing.get('VpcName') or vpc_id} {vpc_id}（{existing.get('CidrBlock')}）")
        vswitches = [(SVC_VSWITCH, free_cidr(vpc, region, existing), "服务机和数据库")]
    else:
        vswitches = VSWITCHES
        existing = describe_vpc(vpc_name=vpc_name)
        if existing:
            vpc_id = existing["VpcId"]
            print(f"[已有] VPC {vpc_name} {vpc_id}（{existing.get('CidrBlock')}）")
        elif not apply:
            print(f"[要建] VPC {vpc_name}（{VPC_CIDR}）——地域里还没有 ACS 集群；有集群的话应该用集群的 VPC")
        else:
            vpc_id = vpc.create_vpc(
                vpc_models.CreateVpcRequest(
                    region_id=region, vpc_name=vpc_name, cidr_block=VPC_CIDR, description=f"ThinkTin {region}（deploy/aliyun）"
                )
            ).body.vpc_id
            wait("VPC", lambda: (describe_vpc(vpc_name=vpc_name) or {}).get("Status") == "Available")
            print(f"[已建] VPC {vpc_name} {vpc_id}")

    for name, cidr, purpose in vswitches:
        found = []
        if vpc_id:
            body = vpc.describe_vswitches(
                vpc_models.DescribeVSwitchesRequest(region_id=region, vpc_id=vpc_id, v_switch_name=name)
            ).body.to_map()
            found = body.get("VSwitches", {}).get("VSwitch", [])
        if found:
            print(f"[已有] 交换机 {name} {found[0]['VSwitchId']}（{found[0].get('CidrBlock')}，{found[0].get('ZoneId')}）")
        elif not apply:
            print(f"[要建] 交换机 {name}（{cidr}，{zone}，{purpose}）")
        else:
            vsw_id = vpc.create_vswitch(
                vpc_models.CreateVSwitchRequest(
                    region_id=region, vpc_id=vpc_id, zone_id=zone, cidr_block=cidr, v_switch_name=name, description=purpose
                )
            ).body.v_switch_id
            print(f"[已建] 交换机 {name} {vsw_id}")

    groups = []
    if vpc_id:
        body = ecs.describe_security_groups(
            ecs_models.DescribeSecurityGroupsRequest(region_id=region, vpc_id=vpc_id, security_group_name=SG_NAME)
        ).body.to_map()
        groups = body.get("SecurityGroups", {}).get("SecurityGroup", [])
    if groups:
        print(f"[已有] 安全组 {SG_NAME} {groups[0]['SecurityGroupId']}")
    elif not apply:
        print(f"[要建] 安全组 {SG_NAME}：入方向只开 {', '.join(p for p, _ in SG_RULES)}，不开 22")
    else:
        sg_id = ecs.create_security_group(
            ecs_models.CreateSecurityGroupRequest(
                region_id=region, vpc_id=vpc_id, security_group_name=SG_NAME, security_group_type="normal",
                description="服务机：只开 80、443",
            )
        ).body.security_group_id
        for ports, why in SG_RULES:
            ecs.authorize_security_group(
                ecs_models.AuthorizeSecurityGroupRequest(
                    region_id=region, security_group_id=sg_id, ip_protocol="tcp", port_range=ports,
                    source_cidr_ip="0.0.0.0/0", policy="accept", description=why,
                )
            )
        print(f"[已建] 安全组 {SG_NAME} {sg_id}（入方向 {', '.join(p for p, _ in SG_RULES)}）")

    print("\n这一阶段的资源都不收费。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # noqa: BLE001 —— 一行说清楚哪里错了，细节看 check
        code = getattr(err, "code", None) or type(err).__name__
        message = (getattr(err, "message", None) or str(err)).splitlines()[0][:200]
        print(f"[失败] {code}: {message}\n      → 先跑 deploy/aliyun/run.sh check，看是哪项权限或产品的问题")
        sys.exit(1)

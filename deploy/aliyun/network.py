"""第 1 阶段：网络（docs/deploy-aliyun-sg.md 第 4 节）。都是不收费的资源：VPC、两个交换机、服务机的安全组。

默认只打印计划，加 --apply 才创建。按名字找已有的资源，重跑不会重复建。

    deploy/aliyun/run.sh network            看要建什么
    deploy/aliyun/run.sh network --apply    建

- VPC `thinktin-sg`（10.10.0.0/16）
- 交换机 `thinktin-svc-a`（10.10.1.0/24，服务机和数据库）、`thinktin-sbx-a`（10.10.16.0/20，agent 沙箱，和服务分开）
- 安全组 `thinktin-svc`：入方向只开 80、443（HTTPS 和证书验证），不开 22（服务机用云助手操作）
"""

import argparse
import sys
import time

from alibabacloud_credentials.client import Client as Credentials
from alibabacloud_ecs20140526 import models as ecs_models
from alibabacloud_ecs20140526.client import Client as Ecs
from alibabacloud_tea_openapi import models as openapi
from alibabacloud_vpc20160428 import models as vpc_models
from alibabacloud_vpc20160428.client import Client as Vpc

VPC_NAME = "thinktin-sg"
VPC_CIDR = "10.10.0.0/16"
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


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-southeast-1")
    parser.add_argument("--apply", action="store_true", help="真的创建（默认只打印计划）")
    args = parser.parse_args()
    region, apply = args.region, args.apply
    zone = f"{region}{ZONE_SUFFIX}"
    vpc = Vpc(config(f"vpc.{region}.aliyuncs.com", region))
    ecs = Ecs(config(f"ecs.{region}.aliyuncs.com", region))
    print(f"地域 {region}，可用区 {zone}。{'创建' if apply else '只看计划（加 --apply 才创建）'}\n")

    def find_vpc():
        body = vpc.describe_vpcs(vpc_models.DescribeVpcsRequest(region_id=region, vpc_name=VPC_NAME)).body.to_map()
        found = body.get("Vpcs", {}).get("Vpc", [])
        return found[0] if found else None

    existing = find_vpc()
    if existing:
        vpc_id = existing["VpcId"]
        print(f"[已有] VPC {VPC_NAME} {vpc_id}（{existing.get('CidrBlock')}）")
    elif not apply:
        vpc_id = None
        print(f"[要建] VPC {VPC_NAME}（{VPC_CIDR}）")
    else:
        vpc_id = vpc.create_vpc(
            vpc_models.CreateVpcRequest(
                region_id=region, vpc_name=VPC_NAME, cidr_block=VPC_CIDR, description="ThinkTin 新加坡（deploy/aliyun）"
            )
        ).body.vpc_id
        wait("VPC", lambda: (find_vpc() or {}).get("Status") == "Available")
        print(f"[已建] VPC {VPC_NAME} {vpc_id}")

    for name, cidr, purpose in VSWITCHES:
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

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

用集群的 VPC 时还给 agent 沙箱建一套单独的网络（阿里云文档“Agent Sandbox 网络规划与扩容”的做法，2026-11-10 实测发现默认
沙箱之间互通、连得上元数据地址）：

- 交换机 `thinktin-sbx-<可用区>`：VPC 里挑一个没用过的 /20，只放沙箱
- 企业级安全组 `thinktin-sbx`（组内隔离，没写的一律不通）：入方向只许集群组件的网段连 envd 49983、49999 和 ICMP；出方向
  拒绝元数据地址 100.100.100.200，只许连服务机网段的模型网关 8790、出网通道 8791 和集群组件网段的 6443、53、49983、9082，
  别的私网地址一律拒绝，阿里云内部服务网段 100.64.0.0/10（镜像仓库、OSS）放行，公网不放
- 两个 ID 存进 `target/aliyun-acs/network.json`，`run.sh acs --pool` 建预热池时写进 SandboxSet 的注解
"""

import argparse
import ipaddress
import json
import os
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
# 模型网关在服务机上监听 8790（主机网络）。ACS 的出网规则只认地址、不分端口，沙箱能不能连服务机的别的端口
# （数据库、k3s 的 6443、kubelet）全靠这里：只许 VPC 里的地址连 8790。ACS 的 Pod 不要放进这个安全组（同组默认互通）。
GATEWAY_PORTS = "8790/8790"
# 受控出网通道（2.7，docs/egress.md）在模型网关里，监听 8791（主机网络）：同样只许 VPC 里的地址连。
EGRESS_PORTS = "8791/8791"

# agent 沙箱自己的交换机和企业级安全组（只在用集群的 VPC 时建）。
SBX_VSWITCH = "thinktin-sbx-{zone}"
SBX_PREFIX = 20
SBX_SG = "thinktin-sbx"
METADATA = "100.100.100.200/32"
PRIVATE = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
# 阿里云内部服务的网段（镜像仓库的 VPC 地址、OSS 内网、内网 DNS 都在里面；元数据地址也在，上面单独拒绝）。
ALIYUN_SERVICES = "100.64.0.0/10"
NETWORK_STATE = "target/aliyun-acs/network.json"


def sandbox_rules(cluster_blocks, svc_block):
    """沙箱安全组的规则：（方向，accept / drop，协议，端口，对端网段，优先级，说明）。优先级数字小的先看，一样时拒绝的赢。"""
    rules = [("egress", "drop", "all", "-1/-1", METADATA, 1, "元数据地址：不让沙箱拿云上的临时凭证")]
    for block in cluster_blocks:
        rules += [
            ("ingress", "accept", "tcp", "49983/49983", block, 1, "sandbox-manager、控制器连 envd"),
            ("ingress", "accept", "tcp", "49999/49999", block, 1, "sandbox-manager 连 jupyter"),
            ("ingress", "accept", "icmp", "-1/-1", block, 1, "健康探测"),
            ("egress", "accept", "tcp", "6443/6443", block, 1, "ACS 实例连 API Server"),
            ("egress", "accept", "tcp", "53/53", block, 1, "CoreDNS"),
            ("egress", "accept", "udp", "53/53", block, 1, "CoreDNS"),
            ("egress", "accept", "tcp", "49983/49983", block, 1, "沙箱控制器的服务"),
            ("egress", "accept", "tcp", "9082/9082", block, 1, "Poseidon 托管组件"),
        ]
    if svc_block:
        rules.append(("egress", "accept", "tcp", "8790/8791", svc_block, 1, "服务机上的模型网关和出网通道"))
    rules += [("egress", "drop", "all", "-1/-1", block, 10, "别的私网地址：不让沙箱探内网、互相连") for block in PRIVATE]
    rules.append(("egress", "accept", "all", "-1/-1", ALIYUN_SERVICES, 20, "阿里云内部服务：镜像仓库、OSS、内网 DNS"))
    rules.append(("egress", "drop", "all", "-1/-1", "0.0.0.0/0", 100, "公网：不放（出网只走服务机上的出网通道）"))
    return rules


def vpc_blocks(vpc_entry):
    """VPC 的全部网段：主网段加上附加网段（ACS 的 Pod 交换机可能在附加网段里）。"""
    blocks = [b.strip() for b in str(vpc_entry.get("CidrBlock") or "").split(",") if b.strip()]
    secondary = (vpc_entry.get("SecondaryCidrBlocks") or {}).get("SecondaryCidrBlock") or []
    blocks += [str(b).strip() for b in secondary if str(b).strip() and str(b).strip() not in blocks]
    return blocks


def wanted_rules(blocks):
    """（端口，来源网段，说明）。"""
    rules = [(ports, "0.0.0.0/0", why) for ports, why in SG_RULES]
    for block in blocks:
        rules.append((GATEWAY_PORTS, block, "模型网关：只许 VPC 里的沙箱连"))
        rules.append((EGRESS_PORTS, block, "出网通道：只许 VPC 里的沙箱连"))
    return rules


def config(endpoint, region):
    return openapi.Config(credential=Credentials(), endpoint=endpoint, region_id=region)


def wait(what, fn, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if fn():
            return
        time.sleep(3)
    raise TimeoutError(f"{what} 等了 {timeout} 秒还没就绪")


def free_cidr(vpc, region, existing, prefix=24, skip=()):
    """在已有 VPC 的网段里挑第一个和现有交换机（以及 `skip` 里的网段）都不重叠的 /prefix。"""
    body = vpc.describe_vswitches(
        vpc_models.DescribeVSwitchesRequest(region_id=region, vpc_id=existing["VpcId"], page_size=50)
    ).body.to_map()
    used = [ipaddress.ip_network(v["CidrBlock"]) for v in body.get("VSwitches", {}).get("VSwitch", []) if v.get("CidrBlock")]
    used += [ipaddress.ip_network(b) for b in skip]
    for block in vpc_blocks(existing):
        for net in ipaddress.ip_network(block).subnets(new_prefix=prefix):
            if not any(net.overlaps(u) for u in used):
                return str(net)
    raise RuntimeError(f"VPC {existing['VpcId']} 的网段里没有空的 /{prefix} 了")


def sandbox_network(vpc, ecs, region, existing, zone, apply):
    """给 agent 沙箱建单独的交换机和企业级安全组（都不收费），把 ID 存进 NETWORK_STATE。"""
    vpc_id = existing["VpcId"]
    body = vpc.describe_vswitches(vpc_models.DescribeVSwitchesRequest(region_id=region, vpc_id=vpc_id, page_size=50)).body.to_map()
    vswitches = body.get("VSwitches", {}).get("VSwitch", [])
    name = SBX_VSWITCH.format(zone=zone[-1])
    cluster_blocks = sorted(v["CidrBlock"] for v in vswitches if str(v.get("VSwitchName", "")).startswith("k8s-vswitch-"))
    svc = [v["CidrBlock"] for v in vswitches if v.get("VSwitchName") == SVC_VSWITCH]
    svc_block = svc[0] if svc else None
    print(f"\nagent 沙箱的网络（集群组件的网段 {'、'.join(cluster_blocks) or '没找到'}；服务机的网段 {svc_block or '还没建'}）：")
    if not cluster_blocks:
        raise RuntimeError("没找到集群自带的交换机（k8s-vswitch-…），不知道该放行哪些网段")

    # 集群是双栈的（Pod 同时要 IPv4 和 IPv6 地址）：VPC 有 IPv6 网段的话，沙箱的交换机也要开 IPv6，不然 Pod 起不来
    # （Ipv6AddressNotSupportVsw，2026-11-10）。挑一个没用过的 /64（VPC 的 /56 后面 8 位）。安全组没有 IPv6 规则，企业级
    # 安全组默认全拒，所以沙箱之间、沙箱往外的 IPv6 都不通。
    ipv6_index = None
    if existing.get("Ipv6CidrBlock"):
        taken = {int(ipaddress.ip_network(v["Ipv6CidrBlock"]).network_address.exploded.split(":")[3], 16) & 0xFF
                 for v in vswitches if v.get("Ipv6CidrBlock")}
        ipv6_index = next(i for i in range(16, 256) if i not in taken)

    found = [v for v in vswitches if v.get("VSwitchName") == name]
    vsw_id = found[0]["VSwitchId"] if found else None
    if found:
        print(f"[已有] 交换机 {name} {vsw_id}（{found[0].get('CidrBlock')}，{found[0].get('ZoneId')}，"
              f"IPv6 {found[0].get('Ipv6CidrBlock') or '没开'}）")
        if ipv6_index is not None and not found[0].get("Ipv6CidrBlock"):
            if not apply:
                print(f"[要改] 交换机 {name} 打开 IPv6（VPC {existing['Ipv6CidrBlock']} 里的第 {ipv6_index} 个 /64，不收费）")
            else:
                vpc.modify_vswitch_attribute(
                    vpc_models.ModifyVSwitchAttributeRequest(
                        region_id=region, v_switch_id=vsw_id, enable_ipv6=True, ipv_6cidr_block=ipv6_index,
                    )
                )
                print(f"[已改] 交换机 {name} 打开了 IPv6（第 {ipv6_index} 个 /64）")
    else:
        # 服务机的交换机这一轮可能还没建（只看计划时），先把它要用的那个 /24 让出来。
        skip = [] if svc_block else [free_cidr(vpc, region, existing)]
        cidr = free_cidr(vpc, region, existing, SBX_PREFIX, skip)
        if not apply:
            print(f"[要建] 交换机 {name}（{cidr}，{zone}，只放 agent 沙箱）")
        else:
            vsw_id = vpc.create_vswitch(
                vpc_models.CreateVSwitchRequest(
                    region_id=region, vpc_id=vpc_id, zone_id=zone, cidr_block=cidr, v_switch_name=name, description="agent 沙箱",
                    ipv_6cidr_block=ipv6_index,
                )
            ).body.v_switch_id
            print(f"[已建] 交换机 {name} {vsw_id}（{cidr}）")

    groups = ecs.describe_security_groups(
        ecs_models.DescribeSecurityGroupsRequest(region_id=region, vpc_id=vpc_id, security_group_name=SBX_SG)
    ).body.to_map().get("SecurityGroups", {}).get("SecurityGroup", [])
    sg_id = groups[0]["SecurityGroupId"] if groups else None
    have = set()
    if groups:
        print(f"[已有] 安全组 {SBX_SG} {sg_id}（{groups[0].get('SecurityGroupType')}）")
        attrs = ecs.describe_security_group_attribute(
            ecs_models.DescribeSecurityGroupAttributeRequest(region_id=region, security_group_id=sg_id)
        ).body.to_map()
        for p in attrs.get("Permissions", {}).get("Permission", []):
            direction = str(p.get("Direction", "")).lower()
            peer = p.get("SourceCidrIp") if direction == "ingress" else p.get("DestCidrIp")
            have.add((direction, str(p.get("Policy", "")).lower(), str(p.get("IpProtocol", "")).lower(), p.get("PortRange"), peer,
                      int(p.get("Priority") or 1)))
    elif not apply:
        print(f"[要建] 企业级安全组 {SBX_SG}（组内隔离）")
    else:
        sg_id = ecs.create_security_group(
            ecs_models.CreateSecurityGroupRequest(
                region_id=region, vpc_id=vpc_id, security_group_name=SBX_SG, security_group_type="enterprise",
                description="agent 沙箱：组内隔离，只许连模型网关、出网通道和集群组件",
            )
        ).body.security_group_id
        print(f"[已建] 企业级安全组 {SBX_SG} {sg_id}")

    for direction, policy, proto, ports, peer, priority, why in sandbox_rules(cluster_blocks, svc_block):
        if (direction, policy, proto, ports, peer, priority) in have:
            continue
        shown = f"{'入' if direction == 'ingress' else '出'}方向 {'允许' if policy == 'accept' else '拒绝'} {proto} {ports} {peer}（优先级 {priority}，{why}）"
        if not apply:
            print(f"[要加] {shown}")
            continue
        if direction == "ingress":
            ecs.authorize_security_group(
                ecs_models.AuthorizeSecurityGroupRequest(
                    region_id=region, security_group_id=sg_id, ip_protocol=proto, port_range=ports, source_cidr_ip=peer,
                    policy=policy, priority=str(priority), description=why,
                )
            )
        else:
            ecs.authorize_security_group_egress(
                ecs_models.AuthorizeSecurityGroupEgressRequest(
                    region_id=region, security_group_id=sg_id, ip_protocol=proto, port_range=ports, dest_cidr_ip=peer,
                    policy=policy, priority=str(priority), description=why,
                )
            )
        print(f"[已加] {shown}")

    if vsw_id and sg_id:
        os.makedirs(os.path.dirname(NETWORK_STATE), exist_ok=True)
        with open(NETWORK_STATE, "w") as f:
            json.dump({"vpc_id": vpc_id, "sandbox_vswitch_id": vsw_id, "sandbox_security_group_id": sg_id}, f)
        print(f"沙箱的交换机和安全组 ID 存在 {NETWORK_STATE}（建预热池时写进 SandboxSet 的注解）。")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--vpc-id", help="用这个 VPC（默认用地域里 ACS 集群的 VPC）")
    parser.add_argument("--apply", action="store_true", help="真的创建（默认只打印计划）")
    parser.add_argument("--sandbox-zone", default="c", help="agent 沙箱的交换机放哪个可用区（2026-11-10 实测沙箱在 c 区起得来）")
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

    rules = wanted_rules(vpc_blocks(existing) if existing else [VPC_CIDR])
    shown = "、".join(f"{p.split('/')[0]}（{src}）" for p, src, _ in rules)
    groups = []
    if vpc_id:
        body = ecs.describe_security_groups(
            ecs_models.DescribeSecurityGroupsRequest(region_id=region, vpc_id=vpc_id, security_group_name=SG_NAME)
        ).body.to_map()
        groups = body.get("SecurityGroups", {}).get("SecurityGroup", [])
    if groups:
        sg_id = groups[0]["SecurityGroupId"]
        print(f"[已有] 安全组 {SG_NAME} {sg_id}")
        attrs = ecs.describe_security_group_attribute(
            ecs_models.DescribeSecurityGroupAttributeRequest(region_id=region, security_group_id=sg_id, direction="ingress")
        ).body.to_map()
        have = {
            (p.get("PortRange"), p.get("SourceCidrIp"))
            for p in attrs.get("Permissions", {}).get("Permission", [])
            if str(p.get("IpProtocol", "")).lower() == "tcp" and p.get("Policy", "Accept").lower() == "accept"
        }
        for ports, src, why in rules:
            if (ports, src) in have:
                continue
            if not apply:
                print(f"[要加] 安全组 {SG_NAME} 入方向 TCP {ports} 来自 {src}（{why}）")
                continue
            ecs.authorize_security_group(
                ecs_models.AuthorizeSecurityGroupRequest(
                    region_id=region, security_group_id=sg_id, ip_protocol="tcp", port_range=ports,
                    source_cidr_ip=src, policy="accept", description=why,
                )
            )
            print(f"[已加] 安全组 {SG_NAME} 入方向 TCP {ports} 来自 {src}")
    elif not apply:
        print(f"[要建] 安全组 {SG_NAME}：入方向只开 {shown}，不开 22")
    else:
        sg_id = ecs.create_security_group(
            ecs_models.CreateSecurityGroupRequest(
                region_id=region, vpc_id=vpc_id, security_group_name=SG_NAME, security_group_type="normal",
                description="服务机：公网只开 80、443，VPC 里只开模型网关 8790、出网通道 8791",
            )
        ).body.security_group_id
        for ports, src, why in rules:
            ecs.authorize_security_group(
                ecs_models.AuthorizeSecurityGroupRequest(
                    region_id=region, security_group_id=sg_id, ip_protocol="tcp", port_range=ports,
                    source_cidr_ip=src, policy="accept", description=why,
                )
            )
        print(f"[已建] 安全组 {SG_NAME} {sg_id}（入方向 {shown}）")

    if owner and owner.startswith("ACS 集群") and existing:
        sandbox_network(vpc, ecs, region, existing, f"{region}{args.sandbox_zone}", apply)

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

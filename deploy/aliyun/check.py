"""阿里云部署前的只读检查（docs/deploy-aliyun-sg.md 第 4 节开工前跑）。

查 Key 能不能用、是哪个身份、选定地域有没有服务机要用的规格、各产品开没开通、账户余额。只调查询接口，不建任何资源，
不打印密钥。每一项打印“通过 / 不通过”和原因，不通过的给出该去哪儿处理。

    deploy/aliyun/run.sh check                       默认新加坡 ap-southeast-1
    deploy/aliyun/run.sh check --region ap-northeast-1
"""

import argparse
import os
import sys

import oss2
from alibabacloud_bssopenapi20171214.client import Client as Bss
from alibabacloud_credentials.client import Client as Credentials
from alibabacloud_cs20151215 import models as cs_models
from alibabacloud_cs20151215.client import Client as Cs
from alibabacloud_ecs20140526 import models as ecs_models
from alibabacloud_ecs20140526.client import Client as Ecs
from alibabacloud_rds20140815 import models as rds_models
from alibabacloud_rds20140815.client import Client as Rds
from alibabacloud_sts20150401.client import Client as Sts
from alibabacloud_tea_openapi import models as openapi
from alibabacloud_vpc20160428 import models as vpc_models
from alibabacloud_vpc20160428.client import Client as Vpc

KEY_ID = "ALIBABA_CLOUD_ACCESS_KEY_ID"
KEY_SECRET = "ALIBABA_CLOUD_ACCESS_KEY_SECRET"

# 服务机的候选规格（4 核 8G，按顺序优先），见部署计划第 2 节。
SERVER_TYPES = ["ecs.u1-c1m2.xlarge", "ecs.c8i.xlarge", "ecs.c7.xlarge", "ecs.c9i.xlarge"]

# 接口报“没权限”时，子账号 thinktin-deploy 缺的系统策略（部署计划第 3 节）。
POLICY = {
    "sts": "无（任何 Key 都能查自己的身份）",
    "ecs": "AliyunECSFullAccess",
    "vpc": "AliyunVPCFullAccess",
    "rds": "AliyunRDSFullAccess",
    "oss": "AliyunOSSFullAccess",
    "cs": "AliyunCSFullAccess",
    "bss": "AliyunBSSReadOnlyAccess",
}

results = []


def config(endpoint, region):
    return openapi.Config(credential=Credentials(), endpoint=endpoint, region_id=region)


def explain(product, err):
    """把接口错误翻成一句处理办法。"""
    code = getattr(err, "code", None) or type(err).__name__
    message = getattr(err, "message", None) or str(err)
    hint = ""
    if code in ("InvalidAccessKeyId", "InvalidAccessKeyId.NotFound", "InvalidAccessKeyId.Inactive"):
        hint = "Key 不存在或被禁用：在 RAM 里看 thinktin-deploy 的 AccessKey，环境变量里的 ID 是否对得上"
    elif code in ("SignatureDoesNotMatch", "IncompleteSignature"):
        hint = "Secret 不对：重新复制 AccessKey Secret 填进环境变量，注意前后不要有空格"
    elif "Forbidden" in code or "NoPermission" in code or code in ("AccessDenied", "403"):
        hint = f"子账号没权限：在 RAM 给 thinktin-deploy 加 {POLICY[product]}"
    elif "NotOpen" in code or "NotActivated" in code or "ServiceNotEnable" in code or "NotApply" in code:
        hint = "产品还没开通：到控制台开通（第一次开通要本人同意协议、授权服务角色）"
    return f"{code}: {message.splitlines()[0][:200]}" + (f"\n      → {hint}" if hint else "")


def check(name, product, fn):
    try:
        detail = fn()
        results.append((name, True, detail))
        print(f"[通过] {name}：{detail}")
    except Exception as err:  # noqa: BLE001 —— 每一项都要接着查下去
        detail = explain(product, err)
        results.append((name, False, detail))
        print(f"[不通过] {name}：{detail}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-southeast-1")
    args = parser.parse_args()
    region = args.region

    missing = [v for v in (KEY_ID, KEY_SECRET) if not os.environ.get(v)]
    if missing:
        print(f"[不通过] 环境变量里没有 {'、'.join(missing)}。")
        print("      → 在云端环境设置的“环境变量”（不是设置脚本，也不是 Network secrets）里填，保存后开新会话。")
        return 1
    print(f"Key：已读到（不显示）。地域：{region}\n")

    def identity():
        body = Sts(config(f"sts.{region}.aliyuncs.com", region)).get_caller_identity().body
        kind = body.identity_type
        warn = "（这是主账号的 Key，建议换成子账号 thinktin-deploy 的）" if kind == "Account" else ""
        return f"{kind} {body.arn}{warn}"

    check("Key 和身份", "sts", identity)

    def server_types():
        req = ecs_models.DescribeAvailableResourceRequest(
            region_id=region,
            destination_resource="InstanceType",
            instance_charge_type="PostPaid",
        )
        body = Ecs(config(f"ecs.{region}.aliyuncs.com", region)).describe_available_resource(req).body.to_map()
        found = {}
        for zone in body.get("AvailableZones", {}).get("AvailableZone", []):
            for res in zone.get("AvailableResources", {}).get("AvailableResource", []):
                for item in res.get("SupportedResources", {}).get("SupportedResource", []):
                    if item.get("Value") in SERVER_TYPES and item.get("Status") == "Available":
                        found.setdefault(item["Value"], []).append(zone["ZoneId"])
        if not found:
            raise RuntimeError(f"候选规格 {SERVER_TYPES} 在 {region} 都没有库存")
        return "；".join(f"{t} 可用区 {', '.join(sorted(z))}" for t, z in sorted(found.items(), key=lambda x: SERVER_TYPES.index(x[0])))

    check("服务机规格（4 核 8G）", "ecs", server_types)

    def vpcs():
        body = Vpc(config(f"vpc.{region}.aliyuncs.com", region)).describe_vpcs(
            vpc_models.DescribeVpcsRequest(region_id=region, page_size=50)
        ).body
        names = [v.vpc_name or v.vpc_id for v in body.vpcs.vpc]
        return f"已有 {body.total_count} 个 VPC" + (f"：{', '.join(names)}" if names else "")

    check("专有网络 VPC", "vpc", vpcs)

    def rds_zones():
        body = Rds(config(f"rds.{region}.aliyuncs.com", region)).describe_available_zones(
            rds_models.DescribeAvailableZonesRequest(region_id=region, engine="PostgreSQL", engine_version="16.0")
        ).body.to_map()
        zones = [z.get("ZoneId") for z in body.get("AvailableZones", [])]
        if not zones:
            raise RuntimeError(f"{region} 没有可买 PostgreSQL 16 的可用区")
        return f"PostgreSQL 16 可用区 {', '.join(zones)}"

    check("数据库 RDS PostgreSQL 16", "rds", rds_zones)

    def oss_buckets():
        auth = oss2.Auth(os.environ[KEY_ID], os.environ[KEY_SECRET])
        service = oss2.Service(auth, f"https://oss-{region}.aliyuncs.com", connect_timeout=15)
        buckets = list(oss2.BucketIterator(service))
        here = [b.name for b in buckets if b.location == f"oss-{region}"]
        return f"账号下共 {len(buckets)} 个桶，本地域 {len(here)} 个" + (f"：{', '.join(here)}" if here else "")

    def oss_check():
        try:
            return oss_buckets()
        except oss2.exceptions.OssError as err:
            # OSS 的错误对象字段名和其他产品不一样，转成同样的形状。
            err.code = err.code or str(err.status)
            err.message = err.message or str(err)
            raise

    check("对象存储 OSS", "oss", oss_check)

    def acs_clusters():
        body = Cs(config(f"cs.{region}.aliyuncs.com", region)).describe_clusters_v1(
            cs_models.DescribeClustersV1Request(region_id=region, page_size=50)
        ).body
        clusters = body.clusters or []
        listed = [f"{c.name}（{c.cluster_type}/{c.profile or '-'}）" for c in clusters]
        return f"已有 {len(clusters)} 个集群" + (f"：{', '.join(listed)}" if listed else "") + \
            "。新加坡能不能开 Agent Sandbox 要在 ACS 控制台确认"

    check("容器计算 ACS", "cs", acs_clusters)

    def balance():
        last = None
        # 国内站账号走 business.aliyuncs.com，国际站走地域地址；哪个能用用哪个。
        for endpoint in ("business.aliyuncs.com", "business.ap-southeast-1.aliyuncs.com"):
            try:
                data = Bss(config(endpoint, region)).query_account_balance().body.data
                return f"可用余额 {data.available_amount} {data.currency}"
            except Exception as err:  # noqa: BLE001
                last = err
        raise last

    check("账户余额", "bss", balance)

    failed = [name for name, ok, _ in results if not ok]
    print()
    if failed:
        print(f"有 {len(failed)} 项不通过：{'、'.join(failed)}。按上面的提示处理后再跑一遍。")
        return 1
    print("全部通过，可以按部署计划第 4 节开始第 1 阶段（先列资源和费用请用户确认）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())

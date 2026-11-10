"""对象存储的桶（docs/deploy-aliyun-sg.md 第 4 节第 1 阶段）：产出物、工作区归档都放在这里（内容在平台里已经加密）。

默认只打印计划，加 --apply 才建（**按用量收费，先问用户**；10 个测试用户每月几毛到几块）。按名字找，重跑不会重复建。

    deploy/aliyun/run.sh oss            看有没有、要建什么
    deploy/aliyun/run.sh oss --apply    建：私有读写、标准存储、禁止公共访问

桶名全网唯一，所以带上账号 ID 的后 6 位：`thinktin-tokyo-<后 6 位>`。服务机经内网地址访问（不收流量费）：
`https://oss-ap-northeast-1-internal.aliyuncs.com`。服务用的访问密钥是另一个只能读写这个桶的子账号的，装服务时再建。
"""

import argparse
import os
import sys

import oss2
from alibabacloud_credentials.client import Client as Credentials
from alibabacloud_sts20150401.client import Client as Sts
from alibabacloud_tea_openapi import models as openapi

KEY_ID, KEY_SECRET = "ALIBABA_CLOUD_ACCESS_KEY_ID", "ALIBABA_CLOUD_ACCESS_KEY_SECRET"
PREFIX = "thinktin-tokyo"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--apply", action="store_true", help="真的建（按用量收费，先问用户）")
    args = parser.parse_args()
    region = args.region
    account = Sts(openapi.Config(credential=Credentials(), endpoint="sts.aliyuncs.com")).get_caller_identity().body.account_id
    name = f"{PREFIX}-{account[-6:]}"
    auth = oss2.Auth(os.environ[KEY_ID], os.environ[KEY_SECRET])
    endpoint = f"https://oss-{region}.aliyuncs.com"
    bucket = oss2.Bucket(auth, endpoint, name, connect_timeout=15)
    try:
        info = bucket.get_bucket_info()
        print(f"[已有] 桶 {name}：{info.location}，{info.storage_class}，{info.acl.grant}，建于 {info.creation_date}")
        exists = True
    except oss2.exceptions.NoSuchBucket:
        exists = False
    if not exists:
        print(f"[要建] 桶 {name}：地域 oss-{region}，标准存储，私有读写，禁止公共访问")
        print("       按用量收费：存储约 ¥0.12/GB/月，请求每万次几分钱；服务机走内网地址不收流量费")
        if not args.apply:
            print("用户同意了再加 --apply。")
            return 0
        bucket.create_bucket(oss2.BUCKET_ACL_PRIVATE, oss2.models.BucketCreateConfig(oss2.BUCKET_STORAGE_CLASS_STANDARD))
        print(f"[已建] 桶 {name}")
    if args.apply:
        try:
            bucket.put_public_access_block(True)
            print("[已设] 禁止公共访问")
        except Exception as err:  # noqa: BLE001 —— 老版本 SDK 或地域不支持时只提示
            print(f"[提示] 没设上“禁止公共访问”（{type(err).__name__}）：桶本身是私有的，去控制台补一下")
    print(f"服务机用的地址：https://oss-{region}-internal.aliyuncs.com，桶 {name}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # noqa: BLE001 —— 一行说清楚哪里错了
        code = getattr(err, "code", None) or type(err).__name__
        message = (getattr(err, "message", None) or str(err)).splitlines()[0][:300]
        print(f"[失败] {code}: {message}")
        sys.exit(1)

"""对象存储的桶（docs/deploy-aliyun-sg.md 第 4 节第 1 阶段）：产出物、工作区归档都放在这里（内容在平台里已经加密）。

默认只打印计划，加 --apply 才建（**按用量收费，先问用户**；10 个测试用户每月几毛到几块）。按名字找，重跑不会重复建。

    deploy/aliyun/run.sh oss            看有没有、要建什么
    deploy/aliyun/run.sh oss --apply    建：私有读写、标准存储、禁止公共访问

桶名全网唯一，所以带上账号 ID 的后 6 位：`thinktin-tokyo-<后 6 位>`。服务机经内网地址访问（不收流量费）：
`https://oss-ap-northeast-1-internal.aliyuncs.com`。

    deploy/aliyun/run.sh oss --service-key --apply   给平台的服务建一把只能读写这个桶的密钥

服务不用部署用的那把大权限 Key：另建一个子账号 `thinktin-oss-tokyo`，只挂一条自定义策略（只许这个桶的读、写、删、列），
给它建 AccessKey，写进本地 `target/thinktin-secrets/oss.env`（0600，不打印、不进仓库；target/ 不在 git 里），再用
`run.sh ecs --push` 传到服务机的 /opt/thinktin/secrets/oss.env（deploy/aliyun/machine/05-secrets.sh 读它）。已经有这个文件
就不再建新的 Key（一个子账号最多两把）。
"""

import argparse
import json
import os
import sys

import oss2
from alibabacloud_credentials.client import Client as Credentials
from alibabacloud_sts20150401.client import Client as Sts
from alibabacloud_tea_openapi import models as openapi
from alibabacloud_tea_openapi.client import Client as OpenApi
from alibabacloud_tea_util import models as util

KEY_ID, KEY_SECRET = "ALIBABA_CLOUD_ACCESS_KEY_ID", "ALIBABA_CLOUD_ACCESS_KEY_SECRET"
PREFIX = "thinktin-tokyo"
SERVICE_USER = "thinktin-oss-tokyo"
SERVICE_POLICY = "ThinktinOssTokyoBucket"
SERVICE_ENV = "target/thinktin-secrets/oss.env"


def ram(action, **query):
    """RAM 的接口（2015-05-01，RPC）。SDK 没装 RAM 的包，用通用客户端调。"""
    client = OpenApi(openapi.Config(credential=Credentials(), endpoint="ram.aliyuncs.com"))
    params = openapi.Params(action=action, version="2015-05-01", protocol="HTTPS", method="POST", auth_type="AK",
                            style="RPC", pathname="/", req_body_type="formData", body_type="json")
    return client.call_api(params, openapi.OpenApiRequest(query=query), util.RuntimeOptions())["body"]


def exists(call):
    try:
        call()
        return True
    except Exception as err:  # noqa: BLE001
        if str(getattr(err, "code", "")).startswith("EntityNotExist"):
            return False
        raise


def service_key(name, apply):
    """只能读写这个桶的子账号和它的 AccessKey。密钥只写进 SERVICE_ENV，不打印。"""
    document = json.dumps({
        "Version": "1",
        "Statement": [
            {"Effect": "Allow", "Action": ["oss:GetObject", "oss:PutObject", "oss:DeleteObject", "oss:AbortMultipartUpload",
                                             "oss:ListParts"],
             "Resource": [f"acs:oss:*:*:{name}/*"]},
            {"Effect": "Allow", "Action": ["oss:ListObjects", "oss:GetBucketInfo", "oss:ListMultipartUploads"],
             "Resource": [f"acs:oss:*:*:{name}"]},
        ],
    })
    have_user = exists(lambda: ram("GetUser", UserName=SERVICE_USER))
    have_policy = exists(lambda: ram("GetPolicy", PolicyName=SERVICE_POLICY, PolicyType="Custom"))
    have_file = os.path.exists(SERVICE_ENV)
    print(f"子账号 {SERVICE_USER}：{'已有' if have_user else '要建'}；策略 {SERVICE_POLICY}（只许桶 {name} 的读、写、删、列）："
          f"{'已有' if have_policy else '要建'}；密钥文件 {SERVICE_ENV}：{'已有，不再建新的' if have_file else '要建'}")
    if not apply:
        print("子账号、策略、密钥都不收费。加 --apply 才建。")
        return 0
    if not have_user:
        ram("CreateUser", UserName=SERVICE_USER, Comments="ThinkTin 东京：平台服务读写 OSS 桶，只有 OpenAPI 访问")
        print(f"[已建] 子账号 {SERVICE_USER}")
    if not have_policy:
        ram("CreatePolicy", PolicyName=SERVICE_POLICY, PolicyDocument=document,
            Description=f"只许读写桶 {name}（deploy/aliyun/oss.py）")
        print(f"[已建] 策略 {SERVICE_POLICY}")
    attached = ram("ListPoliciesForUser", UserName=SERVICE_USER).get("Policies", {}).get("Policy", [])
    if not any(p.get("PolicyName") == SERVICE_POLICY for p in attached):
        ram("AttachPolicyToUser", PolicyName=SERVICE_POLICY, PolicyType="Custom", UserName=SERVICE_USER)
        print(f"[已挂] {SERVICE_POLICY} → {SERVICE_USER}")
    if have_file:
        return 0
    key = ram("CreateAccessKey", UserName=SERVICE_USER)["AccessKey"]
    os.makedirs(os.path.dirname(SERVICE_ENV), mode=0o700, exist_ok=True)
    fd = os.open(SERVICE_ENV, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(f"THINKTIN_S3_ACCESS_KEY_ID={key['AccessKeyId']}\nTHINKTIN_S3_SECRET_ACCESS_KEY={key['AccessKeySecret']}\n")
    print(f"[已建] AccessKey（不显示），写在 {SERVICE_ENV}；传到服务机：run.sh ecs --push {SERVICE_ENV} /opt/thinktin/secrets/oss.env")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--apply", action="store_true", help="真的建（按用量收费，先问用户）")
    parser.add_argument("--service-key", action="store_true", help="给平台的服务建一把只能读写这个桶的密钥")
    args = parser.parse_args()
    region = args.region
    account = Sts(openapi.Config(credential=Credentials(), endpoint="sts.aliyuncs.com")).get_caller_identity().body.account_id
    name = f"{PREFIX}-{account[-6:]}"
    if args.service_key:
        return service_key(name, args.apply)
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

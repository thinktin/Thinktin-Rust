#!/usr/bin/env python3
"""检查 App Store Connect API key 能不能用（.github/workflows/ios-release.yml 在打包前跑，几秒钟就知道，不用等 Rust 编完）。

用 key 签一个 JWT，调几个只读接口，按苹果的回应说清楚是哪种问题。不打印密钥、密钥 id 和 issuer id。

    asc_key_check.py <密钥 id> <issuer id> <.p8 文件> [bundle id]

要 PyJWT 和 cryptography（pip install 'pyjwt[crypto]'）。退出码：0 能用（网络不通时也是 0，只给警告，交给后面的
xcodebuild）；1 不能用，原因写成 GitHub Actions 的 ::error::。
"""
import json
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"


def token(key_id: str, issuer_id: str, private_key: str) -> str:
    import jwt

    now = int(time.time())
    # 苹果要求 exp 不超过 20 分钟。
    claims = {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    return jwt.encode(claims, private_key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def get(path: str, bearer: str) -> tuple[int, dict]:
    """返回 (HTTP 状态, JSON)；连不上时状态是 0。"""
    request = urllib.request.Request(API + path, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.load(error)
        except ValueError:
            return error.code, {}
    except (urllib.error.URLError, TimeoutError) as error:
        return 0, {"reason": str(error)}


def apple_error(body: dict) -> str:
    errors = body.get("errors") or []
    if not errors:
        return ""
    first = errors[0]
    return f"{first.get('code', '')}: {first.get('title', '')}".strip(": ")


def main(argv: list[str]) -> int:
    if len(argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        return 2
    key_id, issuer_id, key_path = argv[1:4]
    bundle_id = argv[4] if len(argv) == 5 else None
    with open(key_path, encoding="utf-8") as handle:
        bearer = token(key_id, issuer_id, handle.read())

    status, body = get("/v1/apps?limit=1", bearer)
    if status == 0:
        print(f"::warning::连不上 App Store Connect，跳过密钥检查：{body.get('reason', '')}")
        return 0
    if status == 401:
        print(
            "::error::苹果不认这把 API 密钥（401 "
            + apple_error(body)
            + "）。最常见：密钥 ID 或 Issuer ID 填错了、和 .p8 文件不是同一把；或者建的是“个人密钥”，要在“团队密钥”里建；"
            "或者这把密钥已经撤销。到 App Store Connect → 用户和访问 → 集成 → 团队密钥 核对后，改 GitHub 里的 ASC_KEY_ID、"
            "ASC_ISSUER_ID、ASC_KEY_P8。"
        )
        return 1
    if status != 200:
        print(f"::error::App Store Connect 返回 {status}（{apple_error(body)}）")
        return 1
    print("API 密钥能用：App 列表 200")

    failed = False
    # 自动签名要登记 bundle id、建证书和描述文件：密钥要“管理（Admin）”权限。
    for path, what in (("/v1/bundleIds?limit=1", "Bundle ID"), ("/v1/certificates?limit=1", "证书")):
        status, body = get(path, bearer)
        if status == 200:
            print(f"{what}：200")
        elif status == 403:
            print(
                f"::error::这把 API 密钥没有{what}的权限（403 {apple_error(body)}）：自动签名要“管理（Admin）”权限的团队密钥，"
                "到 App Store Connect → 用户和访问 → 集成 → 团队密钥 重新建一把，改 GitHub 里的三个密钥。"
            )
            failed = True
        else:
            print(f"::warning::查{what}返回 {status}（{apple_error(body)}）")

    if bundle_id:
        status, body = get(f"/v1/apps?filter[bundleId]={bundle_id}&limit=1", bearer)
        if status == 200 and body.get("data"):
            print(f"App Store Connect 里有 {bundle_id} 的 App 记录")
        elif status == 200:
            print(f"::warning::App Store Connect 里还没有 {bundle_id} 的 App 记录：能打包，上传会失败（App → “+” → 新建 App）")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

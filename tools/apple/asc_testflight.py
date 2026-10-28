#!/usr/bin/env python3
"""TestFlight 内部测试：建（或找到）内部测试组，把 App Store Connect 团队里的人都加进去并发邀请邮件
（.github/workflows/ios-release.yml 手动触发、勾 invite_testers 时跑，不用 Mac）。

    asc_testflight.py <密钥 id> <issuer id> <.p8> <bundle id> [组名]

内部测试员只能是 App Store Connect 里这个团队的用户，所以不收邮箱参数：用 API 读团队用户（要“管理”权限的密钥），
邮箱不进代码、不进公开的日志（打码打印）。内部组能看到所有构建（hasAccessToAllBuilds），新传的构建处理完就能装。
要 PyJWT 和 cryptography（pip install 'pyjwt[crypto]'）。
"""
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_signing import Client, apple_error, fail  # noqa: E402


def masked(email: str) -> str:
    name, _, domain = email.partition("@")
    return f"{name[:1]}***@{domain}" if domain else "***"


def app_id(client: Client, bundle_id: str) -> str:
    status, body = client.call("GET", f"/v1/apps?filter[bundleId]={urllib.parse.quote(bundle_id)}&limit=10")
    if status != 200:
        fail(f"查 App 失败：{status} {apple_error(body)}")
    for item in body.get("data", []):
        if item["attributes"].get("bundleId") == bundle_id:
            return item["id"]
    fail(f"App Store Connect 里没有 {bundle_id} 的 App 记录")
    return ""


def report_builds(client: Client, app: str) -> None:
    status, body = client.call("GET", f"/v1/builds?filter[app]={app}&sort=-uploadedDate&limit=5")
    if status != 200:
        print(f"::warning::查构建失败：{status} {apple_error(body)}")
        return
    for item in body.get("data", []):
        attributes = item["attributes"]
        state = attributes.get("processingState")
        hint = {"PROCESSING": "苹果还在处理，处理完测试组里就能装", "VALID": "可以装", "INVALID": "苹果判定无效，看邮件"}.get(
            state, ""
        )
        print(f"构建 {attributes.get('version')}：{state} {hint}（上传于 {attributes.get('uploadedDate')}）")


def internal_group(client: Client, app: str, name: str) -> str:
    status, body = client.call("GET", f"/v1/apps/{app}/betaGroups?limit=200")
    if status != 200:
        fail(f"查测试组失败：{status} {apple_error(body)}")
    for item in body.get("data", []):
        attributes = item["attributes"]
        if attributes.get("isInternalGroup") and attributes.get("name") == name:
            print(f"内部测试组「{name}」已经有了")
            return item["id"]
    status, body = client.call(
        "POST",
        "/v1/betaGroups",
        {
            "data": {
                "type": "betaGroups",
                "attributes": {"name": name, "isInternalGroup": True, "hasAccessToAllBuilds": True},
                "relationships": {"app": {"data": {"type": "apps", "id": app}}},
            }
        },
    )
    if status != 201:
        fail(f"建内部测试组失败：{status} {apple_error(body)}")
    print(f"建了内部测试组「{name}」（能看到所有构建）")
    return body["data"]["id"]


def existing_tester(client: Client, email: str) -> str | None:
    status, body = client.call("GET", f"/v1/betaTesters?filter[email]={urllib.parse.quote(email)}&limit=10")
    if status == 200:
        for item in body.get("data", []):
            if item["attributes"].get("email", "").lower() == email.lower():
                return item["id"]
    return None


def add_tester(client: Client, app: str, group: str, user: dict) -> None:
    attributes = user["attributes"]
    email = attributes.get("username", "")
    if "@" not in email:
        return
    tester = existing_tester(client, email)
    if tester is None:
        status, body = client.call(
            "POST",
            "/v1/betaTesters",
            {
                "data": {
                    "type": "betaTesters",
                    "attributes": {
                        "email": email,
                        "firstName": attributes.get("firstName") or "",
                        "lastName": attributes.get("lastName") or "",
                    },
                    "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group}]}},
                }
            },
        )
        if status != 201:
            print(f"::warning::加测试员 {masked(email)} 失败：{status} {apple_error(body)}")
            return
        tester = body["data"]["id"]
    else:
        status, body = client.call(
            "POST",
            f"/v1/betaGroups/{group}/relationships/betaTesters",
            {"data": [{"type": "betaTesters", "id": tester}]},
        )
        if status not in (204, 409):
            print(f"::warning::把 {masked(email)} 加进测试组失败：{status} {apple_error(body)}")
            return
    # 显式发一次邀请邮件（已经邀请过时苹果回 409，不算错）。
    status, body = client.call(
        "POST",
        "/v1/betaTesterInvitations",
        {
            "data": {
                "type": "betaTesterInvitations",
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app}},
                    "betaTester": {"data": {"type": "betaTesters", "id": tester}},
                },
            }
        },
    )
    if status in (201, 409):
        print(f"{masked(email)}：已在测试组，邀请邮件已发（或之前发过）")
    else:
        print(f"::warning::给 {masked(email)} 发邀请失败：{status} {apple_error(body)}（App Store Connect 的 TestFlight 里手动点“邀请”）")


def main(argv: list[str]) -> int:
    if len(argv) not in (5, 6):
        print(__doc__, file=sys.stderr)
        return 2
    client = Client(argv[1], argv[2], argv[3])
    bundle_id = argv[4]
    name = argv[5] if len(argv) == 6 else "内部测试"
    app = app_id(client, bundle_id)
    report_builds(client, app)
    group = internal_group(client, app, name)
    status, body = client.call("GET", "/v1/users?limit=200")
    if status != 200:
        fail(f"读团队用户失败：{status} {apple_error(body)}（要“管理”权限的密钥）")
    users = body.get("data", [])
    print(f"团队里 {len(users)} 个用户")
    for user in users:
        add_tester(client, app, group, user)
    print("完成：每个人的邮箱会收到 TestFlight 邀请；手机上装好 TestFlight、用同一个 Apple ID 登录，就能看到 ThinkTin。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

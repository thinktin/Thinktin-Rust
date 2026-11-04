#!/usr/bin/env python3
"""给 CI 的一次发版准备签名用的东西，用完再删（.github/workflows/ios-release.yml 用）。

CI 每次是一台新机器，Xcode 的自动签名会去申请“这台机器”的开发证书，上一次申请的私钥不在，苹果就拒绝；iOS 26 的 SDK
又不许临时签名（“-”）。所以每次发版用 App Store Connect API 现建一张分发证书（私钥只在这台机器上）和每个 bundle id
的 App Store 描述文件，手动签名归档、导出、上传，最后撤销证书、删掉描述文件。

    asc_signing.py setup   <密钥 id> <issuer id> <.p8> <输出目录> <标签> <团队 id> <upload|export> <bundle id>...
    asc_signing.py cleanup <密钥 id> <issuer id> <.p8> <输出目录>

setup 在输出目录里写：signing.p12（和 p12-password）、每个描述文件 <uuid>.mobileprovision、ExportOptions.plist、
signing.xcconfig（按 target 名选描述文件）、state.json（cleanup 要删的证书和描述文件 id）。不打印私钥和密码。
要 PyJWT 和 cryptography（pip install 'pyjwt[crypto]'）。
"""
import base64
import json
import os
import plistlib
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"
# xcodegen 的 target 名 → bundle id（project.yml）。
TARGETS = {"cn.thinktin.Thinktin": "Thinktin", "cn.thinktin.Thinktin.Widgets": "ThinktinWidgets"}
PROFILE_PREFIX = "ThinkTin CI"


class Client:
    def __init__(self, key_id: str, issuer_id: str, key_path: str):
        with open(key_path, encoding="utf-8") as handle:
            self.private_key = handle.read()
        self.key_id = key_id
        self.issuer_id = issuer_id

    def token(self) -> str:
        import jwt

        now = int(time.time())
        claims = {"iss": self.issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
        return jwt.encode(claims, self.private_key, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"})

    def call(self, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
        """连不上（DNS、超时、断连）和 429、5xx 退避重试几次；POST 建证书这类不幂等的，只在请求根本没发出去时重试。"""
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(1, 6):
            request = urllib.request.Request(API + path, data=data, method=method)
            request.add_header("Authorization", f"Bearer {self.token()}")
            if data is not None:
                request.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    raw = response.read()
                    return response.status, json.loads(raw) if raw else {}
            except urllib.error.HTTPError as error:
                raw = error.read()
                try:
                    parsed = json.loads(raw) if raw else {}
                except ValueError:
                    parsed = {}
                if (error.code == 429 or error.code >= 500) and method in ("GET", "DELETE") and attempt < 5:
                    print(f"{method} {path.split('?')[0]} 返回 {error.code}，{attempt * 10} 秒后重试")
                    time.sleep(attempt * 10)
                    continue
                return error.code, parsed
            except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
                if attempt == 5:
                    fail(f"连不上 App Store Connect（{method} {path.split('?')[0]}）：{error}")
                print(f"连不上 App Store Connect（{error}），{attempt * 10} 秒后重试")
                time.sleep(attempt * 10)
        return 0, {}


def apple_error(body: dict) -> str:
    errors = body.get("errors") or []
    return "; ".join(f"{e.get('code', '')}: {e.get('detail') or e.get('title', '')}" for e in errors)


def fail(message: str) -> None:
    print(f"::error::{message}")
    sys.exit(1)


def make_csr():
    """RSA 2048 的私钥和证书签名请求（苹果的证书只认 RSA 2048）。"""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "ThinkTin CI")]))
        .sign(key, hashes.SHA256())
    )
    return key, csr.public_bytes(serialization.Encoding.PEM).decode()


def make_p12(key, cert_der: bytes, password: str) -> bytes:
    """macOS 的 security import 认得的老式 PKCS#12（3DES + SHA1），新式的 AES 在有的系统版本上导不进去。"""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.serialization import PrivateFormat, pkcs12

    cert = x509.load_der_x509_certificate(cert_der)
    encryption = (
        PrivateFormat.PKCS12.encryption_builder()
        .kdf_rounds(50000)
        .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
        .hmac_hash(hashes.SHA1())
        .build(password.encode())
    )
    return pkcs12.serialize_key_and_certificates(b"ThinkTin CI", key, cert, None, encryption)


def bundle_id_resource(client: Client, identifier: str) -> str:
    status, body = client.call(
        "GET", f"/v1/bundleIds?filter[identifier]={urllib.parse.quote(identifier)}&limit=200"
    )
    if status != 200:
        fail(f"查 bundle id {identifier} 失败：{status} {apple_error(body)}")
    # filter 是前缀匹配：cn.thinktin.Thinktin 也会带出 .Widgets，要精确比。
    for item in body.get("data", []):
        if item["attributes"].get("identifier") == identifier:
            return item["id"]
    fail(f"开发者网站上没有 bundle id {identifier}：先在 Identifiers 里登记（App Groups、推送等能力也要开）")
    return ""


def remove_stale_profiles(client: Client) -> None:
    """以前的运行崩了没删掉的描述文件（名字以 ThinkTin CI 开头）先删。"""
    status, body = client.call("GET", f"/v1/profiles?filter[name]={urllib.parse.quote(PROFILE_PREFIX)}&limit=200")
    if status != 200:
        return
    for item in body.get("data", []):
        if item["attributes"].get("name", "").startswith(PROFILE_PREFIX):
            client.call("DELETE", f"/v1/profiles/{item['id']}")
            print(f"删掉以前留下的描述文件：{item['attributes'].get('name')}")


def setup(client: Client, out: str, tag: str, team_id: str, destination: str, bundles: list[str]) -> None:
    os.makedirs(out, exist_ok=True)
    state: dict = {"certificate": None, "profiles": []}
    state_path = os.path.join(out, "state.json")

    def save_state() -> None:
        with open(state_path, "w") as handle:
            json.dump(state, handle)

    remove_stale_profiles(client)
    key, csr = make_csr()
    status, body = client.call(
        "POST",
        "/v1/certificates",
        {"data": {"type": "certificates", "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr}}},
    )
    if status != 201:
        hint = ""
        if status == 409:
            hint = (
                "（分发证书数量到上限了：到开发者网站 Certificates 里撤销不用的 Apple Distribution 证书再跑；"
                "以前 CI 留下的是 Created via API 的那种）"
            )
        fail(f"申请分发证书失败：{status} {apple_error(body)}{hint}")
    cert = body["data"]
    state["certificate"] = cert["id"]
    save_state()
    print(f"分发证书：{cert['attributes'].get('name')}（序列号 {cert['attributes'].get('serialNumber')}）")

    password = secrets.token_hex(16)
    cert_der = base64.b64decode(cert["attributes"]["certificateContent"])
    with open(os.path.join(out, "signing.p12"), "wb") as handle:
        handle.write(make_p12(key, cert_der, password))
    with open(os.path.join(out, "p12-password"), "w") as handle:
        handle.write(password)

    names: dict[str, str] = {}
    for identifier in bundles:
        bundle_resource = bundle_id_resource(client, identifier)
        name = f"{PROFILE_PREFIX} {tag} {identifier}"
        status, body = client.call(
            "POST",
            "/v1/profiles",
            {
                "data": {
                    "type": "profiles",
                    "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                    "relationships": {
                        "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource}},
                        "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]},
                    },
                }
            },
        )
        if status != 201:
            fail(f"建 {identifier} 的描述文件失败：{status} {apple_error(body)}")
        profile = body["data"]
        state["profiles"].append(profile["id"])
        save_state()
        uuid = profile["attributes"]["uuid"]
        with open(os.path.join(out, f"{uuid}.mobileprovision"), "wb") as handle:
            handle.write(base64.b64decode(profile["attributes"]["profileContent"]))
        names[identifier] = name
        print(f"描述文件：{name}（{uuid}）")

    # 每个 target 按名字选自己的描述文件；包里的资源 bundle 之类没有对应的，留空。
    lines = ["CODE_SIGN_STYLE = Manual", "CODE_SIGN_IDENTITY = Apple Distribution", f"DEVELOPMENT_TEAM = {team_id}"]
    for identifier, name in names.items():
        lines.append(f"PROFILE_{TARGETS.get(identifier, identifier.replace('.', '_'))} = {name}")
    lines.append("PROVISIONING_PROFILE_SPECIFIER = $(PROFILE_$(TARGET_NAME))")
    with open(os.path.join(out, "signing.xcconfig"), "w") as handle:
        handle.write("\n".join(lines) + "\n")

    options = {
        "method": "app-store-connect",
        "destination": destination,
        "teamID": team_id,
        "signingStyle": "manual",
        "signingCertificate": "Apple Distribution",
        "provisioningProfiles": names,
        "uploadSymbols": True,
        # 构建号由工作流定（运行序号），不让 App Store Connect 改。
        "manageAppVersionAndBuildNumber": False,
        # 为 true 时只能发给内部测试员；留着外部测试的可能（加到外部测试组要过 Beta 审核）。
        "testFlightInternalTestingOnly": False,
    }
    with open(os.path.join(out, "ExportOptions.plist"), "wb") as handle:
        plistlib.dump(options, handle)


def cleanup(client: Client, out: str) -> None:
    state_path = os.path.join(out, "state.json")
    if not os.path.exists(state_path):
        return
    with open(state_path) as handle:
        state = json.load(handle)
    for profile_id in state.get("profiles", []):
        status, body = client.call("DELETE", f"/v1/profiles/{profile_id}")
        print(f"删描述文件 {profile_id}：{status}")
    if state.get("certificate"):
        status, body = client.call("DELETE", f"/v1/certificates/{state['certificate']}")
        if status not in (204, 404):
            print(f"::warning::撤销分发证书没成功（{status} {apple_error(body)}），到开发者网站 Certificates 里手动撤销")
        else:
            print(f"撤销分发证书：{status}")


def main(argv: list[str]) -> int:
    if len(argv) >= 9 and argv[1] == "setup":
        client = Client(argv[2], argv[3], argv[4])
        setup(client, argv[5], argv[6], argv[7], argv[8], argv[9:])
        return 0
    if len(argv) == 6 and argv[1] == "cleanup":
        cleanup(Client(argv[2], argv[3], argv[4]), argv[5])
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

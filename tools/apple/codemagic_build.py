#!/usr/bin/env python3
"""在 Codemagic 上发起一次构建并跟到结束（.github/workflows/ios-release.yml 选 builder=codemagic 时，GitHub 的 macOS 机器排不上，
改用 Codemagic 的 Mac 打包、传 TestFlight）。

    codemagic_build.py <workflow id> <分支，或者 tag:<标签>> [变量=值 ...]

令牌从环境变量 THINKTIN_AI_CODEMAGIC_API_KEY 读（GitHub 的 Test flight 环境里的 secret），不打印。应用 id 默认是 ThinkTin
在 Codemagic 上的那个，环境变量 CODEMAGIC_APP_ID 可以换。变量=值 作为这次构建的环境变量传过去（只传不机密的：UPLOAD、
CLIENT、构建号这些；苹果的密钥在 Codemagic 的 testflight 变量组里，Secure）。

每一步的状态变了就打印；有步骤失败时打印它日志的最后几十行（GitHub 的日志是公开的：密钥 ID、Issuer ID 这类先遮住）。构建 id 写进 $GITHUB_ENV 的 CODEMAGIC_BUILD_ID（取消时用
`codemagic_build.py --cancel <构建 id>`）。退出码：0 构建成功；1 失败、超时、被取消，或者发不起来。只用标准库。
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

API = "https://api.codemagic.io"
APP_ID = os.environ.get("CODEMAGIC_APP_ID") or "6adfea4501e42548bf7801f4"
TOKEN_VARIABLE = "THINKTIN_AI_CODEMAGIC_API_KEY"
# Codemagic 构建的最终状态。warning 是“完成了但有警告”，算成功。
SUCCESS = {"finished", "warning"}
FAILURE = {"failed", "canceled", "timeout", "skipped"}
LOG_TAIL = 60


def token() -> str:
    value = (os.environ.get(TOKEN_VARIABLE) or "").strip()
    if not value:
        print(
            f"::error::读不到 {TOKEN_VARIABLE}：GitHub 仓库 → Settings → Environments → Test flight → Add environment secret，"
            f"Name 填 {TOKEN_VARIABLE}，Value 粘贴 Codemagic 的 API 令牌"
        )
        sys.exit(1)
    return value


def call(method: str, path: str, body: dict | None = None, *, raw: bool = False, idempotent: bool | None = None):
    """返回 (HTTP 状态, JSON 或文本)；连不上时状态是 0，结果不明（请求可能已经到了）时是 -1。

    幂等的请求（GET、取消）遇到网络抖动、429、5xx 退避重试；发起构建（POST /builds）不幂等，只在 429 或者请求没发完时
    （urllib 把连接、发送阶段的错误包成 URLError）重试；读响应时断了、5xx 都不重发，免得一次发起变成两个构建。"""
    if idempotent is None:
        idempotent = method == "GET"
    data = json.dumps(body).encode() if body is not None else None
    url = path if path.startswith("https://") else API + path
    reason = ""
    for attempt in range(1, 6):
        request = urllib.request.Request(
            url, data=data, method=method, headers={"x-auth-token": token(), "Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = response.read()
                if raw:
                    return response.status, payload.decode("utf-8", "replace")
                try:
                    return response.status, json.loads(payload or b"{}")
                except ValueError:
                    return response.status, {"message": payload[:300].decode("utf-8", "replace")}
        except urllib.error.HTTPError as error:
            if (error.code == 429 or (idempotent and error.code >= 500)) and attempt < 5:
                time.sleep(attempt * 10)
                continue
            text = error.read().decode("utf-8", "replace")
            if raw:
                return error.code, text
            try:
                return error.code, json.loads(text or "{}")
            except ValueError:
                return error.code, {"message": text[:300]}
        except urllib.error.URLError as error:
            # 连接或者发送阶段就失败了（DNS、拒绝连接、连接超时）：Codemagic 没收到完整的请求，重发安全。
            reason = str(error)
            time.sleep(attempt * 10)
        except (TimeoutError, ConnectionError) as error:
            # 请求发出去之后才断的（读响应超时、连接被关）。
            reason = str(error)
            if not idempotent:
                return -1, {"message": reason}
            time.sleep(attempt * 10)
    return 0, {"message": reason}


# 从 Codemagic 的日志抄到 GitHub 的公开日志之前遮住：xcodebuild 的 -authenticationKeyID / -authenticationKeyIssuerID 参数，
# 和形如 Issuer ID 的 UUID（Codemagic 的 Secure 变量只遮原样的值，脚本去掉空格、改小写后的就遮不住了）。
REDACTIONS = (
    (re.compile(r"(-authenticationKey(?:ID|IssuerID))\s+\S+"), r"\1 ***"),
    (re.compile(r"(KEY_ID|ISSUER_ID)=\S+"), r"\1=***"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "***"),
)


def redact(line: str) -> str:
    for pattern, replacement in REDACTIONS:
        line = pattern.sub(replacement, line)
    return line


def steps(build: dict) -> list[dict]:
    """构建里的每一步（buildActions，以及它们的 subactions），按出现的顺序。"""
    found: list[dict] = []

    def walk(items) -> None:
        for item in items or []:
            if isinstance(item, dict):
                if item.get("name") and item.get("status"):
                    found.append(item)
                walk(item.get("subactions"))

    walk(build.get("buildActions"))
    return found


def print_log_tail(step: dict) -> None:
    url = step.get("logUrl")
    if not url:
        return
    status, text = call("GET", url, raw=True)
    if status != 200 or not isinstance(text, str):
        print(f"  （日志读不到：{status}）")
        return
    lines = text.splitlines()
    print(f"::group::「{step['name']}」日志的最后 {min(LOG_TAIL, len(lines))} 行")
    for line in lines[-LOG_TAIL:]:
        print(redact(line))
    print("::endgroup::")


def start(workflow: str, ref: str, variables: dict[str, str]) -> str:
    body = {"appId": APP_ID, "workflowId": workflow}
    if ref.startswith("tag:"):
        body["tag"] = ref[len("tag:") :]
    else:
        body["branch"] = ref
    if variables:
        body["environment"] = {"variables": variables}
    status, response = call("POST", "/builds", body)
    if status == -1:
        print(
            f"::error::发起 Codemagic 构建时连接断了，不知道建没建成（{response.get('message', '')}）：先到 Codemagic 网页上看有没有"
            "刚发起的 ios-testflight，没有再重跑这个工作流（不自动重发，免得同一个构建号打两次）"
        )
        sys.exit(1)
    if status not in (200, 201) or not response.get("buildId"):
        message = response.get("message") or response.get("error") or response
        hint = ""
        if status in (401, 403):
            hint = f"：{TOKEN_VARIABLE} 不对或者已经作废，到 Codemagic 重新复制令牌"
        elif status == 404:
            hint = "：Codemagic 上找不到这个应用（CODEMAGIC_APP_ID）或者分支"
        elif status >= 500:
            hint = "：Codemagic 那边出错，构建可能已经建了；先到 Codemagic 网页上看有没有刚发起的，没有再重跑"
        print(f"::error::Codemagic 发起构建失败（{status} {message}）{hint}")
        sys.exit(1)
    build_id = response["buildId"]
    env_file = os.environ.get("GITHUB_ENV")
    if env_file:
        with open(env_file, "a", encoding="utf-8") as handle:
            handle.write(f"CODEMAGIC_BUILD_ID={build_id}\n")
    print(f"Codemagic 构建已发起：https://codemagic.io/app/{APP_ID}/build/{build_id}")
    return build_id


def follow(build_id: str, deadline_minutes: int) -> int:
    seen: dict[str, str] = {}
    last_status = ""
    misses = 0
    deadline = time.monotonic() + deadline_minutes * 60
    while time.monotonic() < deadline:
        status, response = call("GET", f"/builds/{build_id}")
        if status != 200:
            misses += 1
            # 刚发起的构建头一两次常查不到（404），不算问题。
            if not (status == 404 and not last_status):
                print(f"::warning::查构建状态失败：{status} {response.get('message', '') if isinstance(response, dict) else ''}")
            if misses >= 10:
                print("::error::连续 10 次查不到 Codemagic 的构建状态，不等了（构建本身可能还在跑，到 Codemagic 网页上看）")
                return 1
            time.sleep(30)
            continue
        misses = 0
        build = response.get("build") or {}
        overall = build.get("status", "")
        if overall != last_status:
            print(f"构建状态：{overall}")
            last_status = overall
        for step in steps(build):
            key = str(step.get("_id") or step["name"])
            if seen.get(key) != step["status"]:
                seen[key] = step["status"]
                print(f"  {step['name']}：{step['status']}")
                if step["status"] in FAILURE:
                    print_log_tail(step)
        if overall in SUCCESS:
            print("Codemagic 构建成功")
            return 0
        if overall in FAILURE:
            message = build.get("message") or ""
            print(f"::error::Codemagic 构建没成功：{overall} {message}".rstrip())
            return 1
        time.sleep(30)
    print(f"::error::等了 {deadline_minutes} 分钟 Codemagic 还没跑完，不等了（到 Codemagic 网页上看）")
    return 1


def cancel(build_id: str) -> int:
    status, response = call("POST", f"/builds/{build_id}/cancel", idempotent=True)
    # 208：构建已经结束了。
    print(f"取消 Codemagic 构建 {build_id}：{status}")
    return 0 if status in (200, 202, 204, 208) else 1


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--cancel":
        return cancel(argv[2])
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    workflow, ref = argv[1], argv[2]
    variables: dict[str, str] = {}
    for pair in argv[3:]:
        name, separator, value = pair.partition("=")
        if not separator or not name:
            print(f"变量要写成 名字=值：{pair}", file=sys.stderr)
            return 2
        variables[name] = value
    token()
    build_id = start(workflow, ref, variables)
    return follow(build_id, int(os.environ.get("CODEMAGIC_WAIT_MINUTES") or "140"))


if __name__ == "__main__":
    sys.exit(main(sys.argv))

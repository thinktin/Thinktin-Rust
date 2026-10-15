#!/usr/bin/env python3
"""CI 里把编译错误、clippy 报错和失败的测试变成 GitHub 注解，在 PR 页面和检查结果的接口里都能看到。

用法：
  cargo clippy ... --message-format=json | python3 tools/ci/annotate.py cargo
  python3 tools/ci/annotate.py tests < test.log
"""

import json
import re
import sys

MAX_ANNOTATIONS = 10  # GitHub 每个步骤最多显示 10 条错误注解
MAX_MESSAGE = 6000
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def esc_data(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def esc_prop(s):
    return esc_data(s).replace(":", "%3A").replace(",", "%2C")


def emit(message, file=None, line=None, col=None, title=None):
    message = ANSI.sub("", message).strip()
    if len(message) > MAX_MESSAGE:
        message = message[:MAX_MESSAGE] + "\n...(truncated)"
    props = []
    if file:
        props.append("file=" + esc_prop(file))
    if line:
        props.append("line=%d" % line)
    if col:
        props.append("col=%d" % col)
    if title:
        props.append("title=" + esc_prop(title[:200]))
    head = "::error " + ",".join(props) if props else "::error"
    print("%s::%s" % (head, esc_data(message)), flush=True)


def cargo():
    seen = set()
    count = 0
    for raw in sys.stdin:
        line = raw.rstrip("\n")
        if not line.startswith("{"):
            print(line)
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            print(line)
            continue
        if msg.get("reason") != "compiler-message":
            continue
        diag = msg.get("message") or {}
        rendered = diag.get("rendered") or diag.get("message") or ""
        # 照常把诊断打到日志里。
        sys.stdout.write(rendered)
        if not str(diag.get("level", "")).startswith("error"):
            continue
        if rendered in seen or count >= MAX_ANNOTATIONS:
            continue
        seen.add(rendered)
        span = next((s for s in diag.get("spans") or [] if s.get("is_primary")), None) or {}
        emit(
            rendered,
            file=span.get("file_name"),
            line=span.get("line_start"),
            col=span.get("column_start"),
            title=diag.get("message"),
        )
        count += 1


def tests():
    text = ANSI.sub("", sys.stdin.read())
    blocks = re.findall(
        r"^---- (\S+) stdout ----\n(.*?)(?=^---- |^failures:|^test result:|\Z)",
        text,
        re.S | re.M,
    )
    count = 0
    for name, body in blocks:
        if count >= MAX_ANNOTATIONS:
            break
        emit(body[-MAX_MESSAGE:], title="test failed: " + name)
        count += 1
    if count == 0:
        # 没有单个测试的输出（编译失败、进程崩溃、超时）：给最后一段日志。
        emit("\n".join(text.splitlines()[-120:]), title="cargo test failed")


if __name__ == "__main__":
    {"cargo": cargo, "tests": tests}[sys.argv[1]]()

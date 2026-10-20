#!/usr/bin/env python3
"""按许可证策略检查一个模板的第三方许可清单（WBS 16.5）。

清单由 deploy/templates/licenses.py 在模板镜像里生成（/usr/share/doc/thinktin-agent/licenses.json），
策略在 deploy/templates/license-policy.toml。deny 的许可证让检查失败；review 的、认不出的提醒。
在 GitHub Actions 里写成注解。

用法：
  python3 deploy/templates/license_check.py <licenses.json> [--policy license-policy.toml]
  python3 deploy/templates/license_check.py --self-test
"""

import argparse
import fnmatch
import json
import os
import re
import sys
import tomllib
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPDX_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.+-]*$")
KEYWORDS = {"OR", "AND", "WITH"}


def alternatives(expr):
    """`(A OR B)`、`A AND B`、`A WITH 例外` → 可以选的几组许可证标识（每组都要满足）。"""
    e = expr.strip()
    while e.startswith("(") and e.endswith(")"):
        e = e[1:-1].strip()
    out = []
    for alt in re.split(r"\s+OR\s+", e, flags=re.I):
        alt = re.sub(r"\s+WITH\s+\S+", "", alt.strip("() "), flags=re.I)
        out.append([t.strip("() ") for t in re.split(r"\s+AND\s+", alt, flags=re.I) if t.strip("() ")])
    return out


def classify(expr, policy):
    """('allow' | 'review' | 'deny' | 'unknown', 用来判断的表达式)。"""
    aliases = {k.lower(): v for k, v in policy.get("aliases", {}).items()}
    e = (expr or "").strip()
    e = aliases.get(e.lower(), e)
    if not e or e.upper() in ("UNKNOWN", "UNLICENSED", "NONE", "NOASSERTION") or e.upper().startswith("SEE LICENSE"):
        return "unknown", e or "(none)"

    def level(token):
        token = aliases.get(token.lower(), token)
        if not SPDX_ID.match(token):
            return "unknown"
        for name in ("deny", "review", "allow"):
            if any(fnmatch.fnmatchcase(token.lower(), p.lower()) for p in policy.get(name, [])):
                return name
        return "unknown"

    rank = {"allow": 0, "review": 1, "unknown": 2, "deny": 3}
    best = None
    for group in alternatives(e):
        if not group:
            continue
        worst = max((level(t) for t in group), key=rank.get)
        if best is None or rank[worst] < rank[best]:
            best = worst
    return best or "unknown", e


def check(inventory, policy):
    exceptions = {x["package"]: x["reason"] for x in policy.get("exception", [])}
    result = {"deny": [], "review": [], "unknown": [], "excepted": []}
    licenses = Counter()
    for p in inventory["packages"]:
        verdict, expr = classify(p["license"], policy)
        licenses[expr] += 1
        if p["name"] in exceptions:
            result["excepted"].append((p, exceptions[p["name"]]))
        elif verdict != "allow":
            result[verdict].append(p)
    return result, licenses


def emit(level, title, body):
    if os.environ.get("GITHUB_ACTIONS") != "true":
        return
    esc = lambda s: s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print("::%s title=%s::%s" % (level, esc(title).replace(":", "%3A").replace(",", "%2C"), esc(body)))


def describe(p):
    via = "" if p["top"] in (p["name"], None) else "（经 %s）" % p["top"]
    return "%s %s：%s%s" % (p["name"], p["version"], p["license"], via)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("inventory", nargs="?", type=Path)
    ap.add_argument("--policy", type=Path, default=HERE / "license-policy.toml")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    policy = tomllib.loads(args.policy.read_text(encoding="utf-8"))
    if args.self_test:
        sys.exit(0 if self_test(policy) else 1)
    if not args.inventory:
        ap.error("the inventory is required")
    inventory = json.loads(args.inventory.read_text(encoding="utf-8"))
    agent = inventory["agent"]
    result, licenses = check(inventory, policy)

    total = len(inventory["packages"])
    print("%s：%d 个包。许可证：%s" % (agent, total, "、".join("%s %d" % kv for kv in licenses.most_common(12))))
    for p, why in result["excepted"]:
        print("  例外  %s —— %s" % (describe(p), why))
    for name, label in (("deny", "拦下"), ("review", "待法务看"), ("unknown", "认不出")):
        for p in result[name]:
            print("  %s  %s" % (label, describe(p)))
    if inventory.get("upstream_notices"):
        print("  上游取来的 NOTICE：%s" % "、".join(inventory["upstream_notices"]))

    for p in result["deny"][:10]:
        emit("error", "%s: %s %s is %s" % (agent, p["name"], p["version"], p["license"]),
             "许可证策略不允许（deploy/templates/license-policy.toml 的 deny）：%s" % describe(p))
    notes = [describe(p) for p in result["review"]] + [describe(p) for p in result["unknown"]]
    if notes:
        emit("warning", "%s: %d packages need a license review" % (agent, len(notes)),
             "\n".join(notes[:40]) + ("\n……还有 %d 个" % (len(notes) - 40) if len(notes) > 40 else ""))
    emit("notice", "%s: %d packages, %d excepted, %d to review, %d denied" % (
        agent, total, len(result["excepted"]), len(notes), len(result["deny"])),
        "许可证：" + "、".join("%s %d" % kv for kv in licenses.most_common(12)))
    sys.exit(1 if result["deny"] else 0)


def self_test(policy):
    cases = [
        ("MIT", "allow"),
        ("(MIT OR GPL-3.0)", "allow"),
        ("MIT AND GPL-2.0", "review"),
        ("GPL-2.0 WITH Classpath-exception-2.0", "review"),
        ("AGPL-3.0-only", "deny"),
        ("(AGPL-3.0 OR MIT)", "allow"),
        ("SSPL-1.0", "deny"),
        ("Apache License 2.0", "allow"),
        ("apache 2.0", "allow"),
        ("BSD", "allow"),
        ("SEE LICENSE IN README.md", "unknown"),
        ("UNKNOWN", "unknown"),
        ("", "unknown"),
        ("Custom: https://example.com/license", "unknown"),
        ("LGPL-3.0-or-later", "allow"),
        ("CC-BY-NC-4.0", "deny"),
        ("(BSD-2-Clause OR MIT OR Apache-2.0)", "allow"),
        ("Python-2.0 AND MIT", "allow"),
    ]
    failed = 0
    for expr, want in cases:
        got, _ = classify(expr, policy)
        if got != want:
            failed += 1
            print("FAIL %r: want %s, got %s" % (expr, want, got))
    inv = {"agent": "t", "packages": [
        {"name": "@anthropic-ai/claude-agent-sdk", "version": "1", "top": "x", "license": "SEE LICENSE IN README.md"},
        {"name": "evil", "version": "1", "top": "x", "license": "AGPL-3.0"},
        {"name": "ok", "version": "1", "top": "x", "license": "MIT"},
    ]}
    result, _ = check(inv, policy)
    if [p["name"] for p, _ in result["excepted"]] != ["@anthropic-ai/claude-agent-sdk"] or \
            [p["name"] for p in result["deny"]] != ["evil"] or result["unknown"] or result["review"]:
        failed += 1
        print("FAIL check(): %r" % result)
    print("self-test: %d cases, %d failed" % (len(cases) + 1, failed))
    return failed == 0


if __name__ == "__main__":
    main()

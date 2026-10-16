#!/usr/bin/env python3
"""看上游有没有新版本（WBS 6.8）：清单 [install] 里锁定的每个包，对照 npm、PyPI 上的最新版本。

只报告，不改清单：升级要按 docs/templates.md 的步骤走（改清单、旧清单归档、CI 冒烟、打标签发模板）。
在 GitHub Actions 里有新版本的包写成提醒注解，并汇总到这次运行的摘要页。

用法：python3 deploy/templates/upstream.py [清单目录]
"""

import json
import os
import sys
import tomllib
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def latest_npm(name):
    url = "https://registry.npmjs.org/%s/latest" % urllib.parse.quote(name, safe="@")
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)["version"]


def latest_pypi(name):
    with urllib.request.urlopen("https://pypi.org/pypi/%s/json" % name, timeout=30) as r:
        return json.load(r)["info"]["version"]


def npm_name(spec):
    at = spec.rindex("@", 1)
    return spec[:at], spec[at + 1 :]


def pip_name(spec):
    name, version = spec.split("==", 1)
    return name.split("[", 1)[0], version


def main():
    directory = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "crates/catalog/manifests"
    rows, failures = [], 0
    for path in sorted(directory.glob("*.toml")):
        m = tomllib.loads(path.read_text(encoding="utf-8"))
        agent = m["agent"]["id"]
        inst = m.get("install", {})
        packages = [("npm", *npm_name(s)) for s in inst.get("npm", [])]
        packages += [("pypi", *pip_name(s)) for s in inst.get("pip", [])]
        for registry, name, pinned in packages:
            try:
                latest = (latest_npm if registry == "npm" else latest_pypi)(name)
            except Exception as e:  # noqa: BLE001 - 一个包查不到不影响别的
                failures += 1
                latest = "?（%s）" % e
            rows.append((agent, registry, name, pinned, latest, path))

    lines = ["| agent | 包 | 锁定的版本 | 上游最新 |", "|---|---|---|---|"]
    actions = os.environ.get("GITHUB_ACTIONS") == "true"
    newer = 0
    for agent, registry, name, pinned, latest, path in rows:
        mark = ""
        if not latest.startswith("?") and latest != pinned:
            newer += 1
            mark = " ⬆"
            if actions:
                rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
                print("::warning file=%s,title=%s %s::%s 锁定 %s，上游最新 %s" % (rel, registry, name, agent, pinned, latest))
        lines.append("| %s | %s（%s） | %s | %s%s |" % (agent, name, registry, pinned, latest, mark))
    summary = "\n".join(lines) + "\n\n%d 个包有新版本，%d 个没查到。\n" % (newer, failures)
    print(summary)
    if actions and os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write("## 上游新版本\n\n" + summary)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""看上游有没有新版本（WBS 6.8）、新版本的许可证有没有变（16.5）：清单 [install] 里锁定的每个包，
对照 npm、PyPI 上的最新版本。

只报告，不改清单：升级要按 docs/templates.md 的步骤走（改清单、旧清单归档、CI 冒烟和许可证检查、打标签发模板）。
在 GitHub Actions 里有新版本的包写成提醒注解，许可证变了的写成警告，都汇总到这次运行的摘要页。

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


def get_json(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def npm_info(name, version="latest"):
    """(版本, 许可证)。许可证按 package.json 的 license 字段原样返回。"""
    doc = get_json("https://registry.npmjs.org/%s/%s" % (urllib.parse.quote(name, safe="@"), version))
    lic = doc.get("license")
    if isinstance(lic, dict):
        lic = lic.get("type")
    return doc["version"], lic or "（没写）"


def pypi_info(name, version=None):
    url = "https://pypi.org/pypi/%s/json" % name if version is None else "https://pypi.org/pypi/%s/%s/json" % (name, version)
    info = get_json(url)["info"]
    lic = info.get("license_expression") or (info.get("license") or "").strip()
    if not lic or len(lic) > 80:
        classifiers = [c.split("::")[-1].strip() for c in info.get("classifiers") or [] if c.startswith("License ::")]
        lic = " / ".join(classifiers) or ("（正文太长，见包里的 LICENSE）" if lic else "（没写）")
    return info["version"], lic


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
            info = npm_info if registry == "npm" else pypi_info
            try:
                _, pinned_lic = info(name, pinned)
                latest, latest_lic = info(name) if registry == "pypi" else info(name, "latest")
            except Exception as e:  # noqa: BLE001 - 一个包查不到不影响别的
                failures += 1
                pinned_lic = latest_lic = "?"
                latest = "?（%s）" % e
            rows.append((agent, registry, name, pinned, pinned_lic, latest, latest_lic, path))

    lines = ["| agent | 包 | 锁定的版本 | 许可证 | 上游最新 | 最新版的许可证 |", "|---|---|---|---|---|---|"]
    actions = os.environ.get("GITHUB_ACTIONS") == "true"
    newer = changed = 0
    for agent, registry, name, pinned, pinned_lic, latest, latest_lic, path in rows:
        rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
        mark = lic_mark = ""
        if not latest.startswith("?") and latest != pinned:
            newer += 1
            mark = " ⬆"
            if actions:
                print("::notice file=%s,title=%s %s::%s 锁定 %s，上游最新 %s" % (rel, registry, name, agent, pinned, latest))
        if not latest.startswith("?") and latest_lic != pinned_lic:
            changed += 1
            lic_mark = " ⚠"
            if actions:
                print("::warning file=%s,title=%s %s 的许可证变了::%s：%s 是 %s，%s 是 %s。升级前按 docs/licenses.md 复核"
                      % (rel, registry, name, agent, pinned, pinned_lic, latest, latest_lic))
        lines.append("| %s | %s（%s） | %s | %s | %s%s | %s%s |" % (agent, name, registry, pinned, pinned_lic, latest, mark, latest_lic, lic_mark))
    summary = "\n".join(lines) + "\n\n%d 个包有新版本，%d 个包新版本的许可证变了，%d 个没查到。\n" % (newer, changed, failures)
    print(summary)
    if actions and os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write("## 上游新版本\n\n" + summary)


if __name__ == "__main__":
    main()

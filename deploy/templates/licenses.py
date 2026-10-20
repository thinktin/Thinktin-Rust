#!/usr/bin/env python3
"""模板里装的包的许可证清单（WBS 16.5）。模板构建时在镜像里以 root 跑（deploy/templates/Dockerfile）：

- 全局 npm 包（/usr/local/lib/node_modules，不含 Node 自带的 npm、corepack）和它们的全部依赖；
- agent 的 Python 虚拟环境（/opt/agents/<id>，不含 pip、setuptools 这些虚拟环境自带的）；
- 许可证策略里登记的额外 NOTICE（上游没放进包里的，比如 Codex 的 NOTICE，构建时从上游按版本取）。

输出到 --out（默认 /usr/share/doc/thinktin-agent）：
- licenses.json：每个包的名字、版本、来源、许可证（尽量写成 SPDX）、许可证文件；
- THIRD-PARTY-LICENSES.md：同样的清单，后面附上每个许可证、NOTICE 文件的全文；
- files/<包>@<版本>/...：许可证、NOTICE 文件的原样拷贝。

许可证合不合规由 deploy/templates/license_check.py 按 license-policy.toml 检查（CI 里，镜像外面）。
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tomllib
import urllib.request
from pathlib import Path

NODE_ROOT = Path("/usr/local/lib/node_modules")
NODE_BUILTIN = {"npm", "corepack"}
VENV_BUILTIN = {"pip", "setuptools", "wheel"}
LICENSE_FILE = re.compile(r"^(licen[cs]e|copying|notice|copyright|third[-_]?party)", re.I)

# Python 包常见的许可证分类（Trove classifier）换成 SPDX。
CLASSIFIERS = {
    "MIT License": "MIT",
    "MIT No Attribution License (MIT-0)": "MIT-0",
    "Apache Software License": "Apache-2.0",
    "BSD License": "BSD-3-Clause",
    "ISC License (ISCL)": "ISC",
    "Python Software Foundation License": "PSF-2.0",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
    "The Unlicense (Unlicense)": "Unlicense",
    "Zope Public License": "ZPL-2.1",
    "GNU Lesser General Public License v2 (LGPLv2)": "LGPL-2.0",
    "GNU Lesser General Public License v2 or later (LGPLv2+)": "LGPL-2.0-or-later",
    "GNU Lesser General Public License v3 (LGPLv3)": "LGPL-3.0",
    "GNU Lesser General Public License v3 or later (LGPLv3+)": "LGPL-3.0-or-later",
    "GNU General Public License v2 (GPLv2)": "GPL-2.0",
    "GNU General Public License v2 or later (GPLv2+)": "GPL-2.0-or-later",
    "GNU General Public License v3 (GPLv3)": "GPL-3.0",
    "GNU General Public License v3 or later (GPLv3+)": "GPL-3.0-or-later",
    "GNU Affero General Public License v3": "AGPL-3.0",
    "GNU Affero General Public License v3 or later (AGPLv3+)": "AGPL-3.0-or-later",
}


def npm_license(meta):
    lic = meta.get("license")
    if isinstance(lic, dict):
        lic = lic.get("type")
    if not lic and isinstance(meta.get("licenses"), list):
        types = [x.get("type") if isinstance(x, dict) else str(x) for x in meta["licenses"]]
        types = [t for t in types if t]
        lic = " OR ".join(types)
        if len(types) > 1:
            lic = "(%s)" % lic
    return str(lic).strip() if lic else "UNKNOWN"


def license_files(directory):
    try:
        return sorted(p for p in directory.iterdir() if p.is_file() and LICENSE_FILE.match(p.name))
    except OSError:
        return []


def npm_packages(root):
    out = []
    if not root.is_dir():
        return out
    for pj in sorted(root.rglob("package.json")):
        d = pj.parent
        rel = d.relative_to(root).parts
        # node_modules/<名字> 或 node_modules/@scope/<名字>；包里其他位置的 package.json（测试数据之类）不算。
        if not (d.parent.name == "node_modules" or (d.parent.name.startswith("@") and d.parent.parent.name == "node_modules")):
            continue
        top = "/".join(rel[:2]) if rel[0].startswith("@") else rel[0]
        if top in NODE_BUILTIN:
            continue
        try:
            meta = json.loads(pj.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not meta.get("name") or not meta.get("version"):
            continue
        out.append(
            {
                "name": meta["name"],
                "version": str(meta["version"]),
                "source": "npm",
                "top": top,
                "license": npm_license(meta),
                "files": [str(p) for p in license_files(d)],
            }
        )
    return out


PY_LIST = r"""
import importlib.metadata as md, json, re, sys
pat = re.compile(sys.argv[1], re.I)
out = []
for d in md.distributions():
    m = d.metadata
    files = []
    for f in d.files or []:
        if pat.match(f.name):
            files.append(str(d.locate_file(f)))
    out.append({
        "name": m["Name"], "version": m["Version"],
        "expression": m.get("License-Expression") or "",
        "classifiers": [c.split("::")[-1].strip() for c in (m.get_all("Classifier") or []) if c.startswith("License ::")],
        "license": (m.get("License") or "").strip(),
        "files": files,
    })
print(json.dumps(out))
"""


def pip_packages(venv, top):
    python = venv / "bin" / "python"
    if not python.exists():
        return []
    raw = json.loads(subprocess.check_output([str(python), "-c", PY_LIST, LICENSE_FILE.pattern]))
    out = []
    for p in raw:
        if p["name"].lower() in VENV_BUILTIN:
            continue
        if p["expression"]:
            lic = p["expression"]
        elif p["classifiers"]:
            names = [CLASSIFIERS.get(c, c) for c in p["classifiers"]]
            lic = names[0] if len(names) == 1 else "(%s)" % " OR ".join(names)
        elif p["license"] and len(p["license"]) <= 80 and "\n" not in p["license"]:
            lic = p["license"]
        else:
            lic = "UNKNOWN"
        out.append(
            {
                "name": p["name"],
                "version": p["version"],
                "source": "pypi",
                "top": top,
                "license": lic,
                "files": sorted(set(p["files"])),
            }
        )
    return out


def extra_notices(policy, packages, dest):
    """策略里登记的上游 NOTICE（包里没带的），按装上的版本下载。"""
    fetched = []
    for n in policy.get("notice", []):
        pkg = next((p for p in packages if p["name"] == n["package"]), None)
        if pkg is None:
            continue
        url = n["url"].replace("{version}", pkg["version"])
        target = dest / ("upstream-" + Path(n["url"]).name)
        with urllib.request.urlopen(url, timeout=60) as r, open(target, "wb") as f:
            f.write(r.read())
        pkg["files"].append(str(target))
        fetched.append(url)
    return fetched


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--agent", required=True)
    ap.add_argument("--policy", required=True, type=Path)
    ap.add_argument("--out", default="/usr/share/doc/thinktin-agent", type=Path)
    args = ap.parse_args()

    policy = tomllib.loads(args.policy.read_text(encoding="utf-8"))
    # 同一个版本可能在依赖树里装了好几份：只列一次。
    unique = {}
    for p in npm_packages(NODE_ROOT) + pip_packages(Path("/opt/agents") / args.agent, args.agent):
        key = (p["source"], p["name"], p["version"])
        if key in unique:
            unique[key]["files"] = sorted(set(unique[key]["files"]) | set(p["files"]))
        else:
            unique[key] = p
    packages = list(unique.values())
    if not packages:
        sys.exit("no packages found: is the agent installed?")
    out = args.out
    files_dir = out / "files"
    files_dir.mkdir(parents=True, exist_ok=True)
    fetched = extra_notices(policy, packages, files_dir)

    texts = []
    for p in sorted(packages, key=lambda p: (p["name"].lower(), p["version"])):
        target = files_dir / ("%s@%s" % (p["name"].replace("/", "__"), p["version"]))
        copied = []
        for f in p["files"]:
            src = Path(f)
            if not src.is_file():
                continue
            if src.parent != files_dir:
                target.mkdir(parents=True, exist_ok=True)
                dst = target / src.name
                shutil.copyfile(src, dst)
            else:
                dst = src
            copied.append(str(dst.relative_to(out)))
            texts.append((p, dst))
        p["files"] = copied

    packages.sort(key=lambda p: (p["name"].lower(), p["version"]))
    (out / "licenses.json").write_text(
        json.dumps({"agent": args.agent, "packages": packages, "upstream_notices": fetched}, ensure_ascii=False, indent=1),
        encoding="utf-8",
    )
    with open(out / "THIRD-PARTY-LICENSES.md", "w", encoding="utf-8") as f:
        f.write("# Third-party software in the %s sandbox template\n\n" % args.agent)
        f.write("| Package | Version | Source | License |\n|---|---|---|---|\n")
        for p in packages:
            f.write("| %s | %s | %s | %s |\n" % (p["name"], p["version"], p["source"], p["license"].replace("|", "\\|")))
        f.write("\n## License and notice texts\n")
        seen = {}
        for p, path in texts:
            body = path.read_text(encoding="utf-8", errors="replace").strip()
            key = hash(body)
            if key in seen:
                f.write("\n### %s %s — %s\n\nSame text as %s.\n" % (p["name"], p["version"], path.name, seen[key]))
                continue
            seen[key] = "%s %s (%s)" % (p["name"], p["version"], path.name)
            f.write("\n### %s %s — %s\n\n```\n%s\n```\n" % (p["name"], p["version"], path.name, body.replace("```", "'''")))
    print("%d packages, %d license or notice files -> %s" % (len(packages), len(texts), out))


if __name__ == "__main__":
    main()

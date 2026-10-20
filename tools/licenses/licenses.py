#!/usr/bin/env python3
"""第三方许可证清单和许可证策略检查（WBS 16.5，说明见 docs/licenses.md）。

只用标准库（Python 3.11 以上），在模板镜像里、CI 主机上、Rust 的构建镜像里都能跑。

  scan     扫描装好的 npm 包、Python 包、Debian 包（模板镜像构建时在镜像里跑），
           把许可证、NOTICE 原文复制到输出目录，写清单 inventory.json 和索引 NOTICES.md
  cargo    按 cargo metadata 列出几个程序实际依赖的 crate，同样复制原文、写清单
  check    按策略（tools/licenses/policy.toml）检查清单：禁止的许可证、没登记的专有或认不出的许可证、
           清单里 agent 的许可证和上游对不上
  self-test  内置测试

输出目录（模板镜像里是 /usr/share/thinktin/licenses）：
  inventory.json   每个组件一条：生态、名字、版本、许可证（SPDX 表达式）、原文的位置
  NOTICES.md       人看的索引：按许可证汇总、每个组件的许可证和原文位置
  texts/<生态>/<名字>@<版本>/   复制来的 LICENSE、NOTICE 原文（Debian 包的原文就在 /usr/share/doc/<包>/copyright）
"""

import argparse
import email.parser
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

SCHEMA = 1
MAX_TEXT_BYTES = 1 << 20  # 单个原文文件的上限，超过的只记路径不复制
MAX_ANNOTATIONS = 30
# 包里没带原文的组件，用 SPDX 的标准文本（spdx/ 下，取自 spdx/license-list-data v3.29.0），加上元数据里的作者。
SPDX_DIR = Path(__file__).resolve().with_name("spdx")
NODE_LICENSE_URL = "https://raw.githubusercontent.com/nodejs/node/v%s/LICENSE"

# ---------------------------------------------------------------------------
# SPDX 表达式

_TOKEN = re.compile(r"\s*(\(|\)|[A-Za-z0-9.+:_-]+)")
_OPS = {"AND", "OR", "WITH"}


class SpdxError(ValueError):
    pass


def parse_spdx(text):
    """解析 SPDX 表达式，返回语法树：("id", 名字) / ("with", 名字, 例外) / ("and" | "or", [子树...])。

    运算符不分大小写（npm 上有人写小写的 `and`、`or`）。语法不对时抛 SpdxError。
    """
    tokens, pos = [], 0
    text = text.strip()
    while pos < len(text):
        m = _TOKEN.match(text, pos)
        if not m:
            raise SpdxError("无法解析的字符：%r" % text[pos:])
        tokens.append(m.group(1))
        pos = m.end()
    if not tokens:
        raise SpdxError("空表达式")
    i = 0

    def peek():
        return tokens[i].upper() if i < len(tokens) else None

    def take():
        nonlocal i
        i += 1
        return tokens[i - 1]

    def expr_or():
        items = [expr_and()]
        while peek() == "OR":
            take()
            items.append(expr_and())
        return items[0] if len(items) == 1 else ("or", items)

    def expr_and():
        items = [expr_with()]
        while peek() == "AND":
            take()
            items.append(expr_with())
        return items[0] if len(items) == 1 else ("and", items)

    def expr_with():
        node = atom()
        if peek() == "WITH":
            take()
            if peek() in (None, "(", ")") or peek() in _OPS:
                raise SpdxError("WITH 后面要跟例外的名字")
            if node[0] != "id":
                raise SpdxError("WITH 只能跟在单个许可证后面")
            node = ("with", node[1], take())
        return node

    def atom():
        tok = peek()
        if tok is None:
            raise SpdxError("表达式不完整")
        if tok == "(":
            take()
            node = expr_or()
            if peek() != ")":
                raise SpdxError("括号不配对")
            take()
            return node
        if tok == ")" or tok in _OPS:
            raise SpdxError("这里应该是许可证名字：%s" % tokens[i])
        return ("id", take())

    tree = expr_or()
    if i != len(tokens):
        raise SpdxError("多余的内容：%s" % " ".join(tokens[i:]))
    return tree


def render_spdx(tree, top=True):
    kind = tree[0]
    if kind == "id":
        return tree[1]
    if kind == "with":
        return "%s WITH %s" % (tree[1], tree[2])
    joined = (" %s " % kind.upper()).join(render_spdx(t, False) for t in tree[1])
    return joined if top else "(%s)" % joined


def spdx_ids(tree):
    if tree[0] in ("id", "with"):
        return [tree[1]]
    return [x for t in tree[1] for x in spdx_ids(t)]


def is_spdx(text):
    try:
        tree = parse_spdx(text)
    except SpdxError:
        return False
    return all(_looks_like_id(x) for x in spdx_ids(tree))


def _looks_like_id(x):
    # SPDX 的许可证标识都是不带空格的一个词；“MIT License”“BSD”这类自由文本会被拆成几个词，解析就会失败。
    return x.upper() not in _OPS and (x in KNOWN_IDS or x.startswith("LicenseRef-") or x.upper() in KNOWN_UPPER)


# 常见的 SPDX 标识（不求全：不在这里、也不是 LicenseRef- 的词按自由文本处理）。
KNOWN_IDS = set(
    """
0BSD AFL-2.1 AFL-3.0 AGPL-1.0 AGPL-3.0 AGPL-3.0-only AGPL-3.0-or-later Apache-1.1 Apache-2.0 APSL-2.0
Artistic-1.0 Artistic-2.0 BlueOak-1.0.0 BSD-1-Clause BSD-2-Clause BSD-2-Clause-Patent BSD-3-Clause
BSD-3-Clause-Clear BSD-4-Clause BSL-1.0 BUSL-1.1 bzip2-1.0.6 CAL-1.0 CC-BY-3.0 CC-BY-4.0 CC-BY-NC-4.0
CC-BY-NC-SA-4.0 CC-BY-ND-4.0 CC-BY-SA-3.0 CC-BY-SA-4.0 CC0-1.0 CDDL-1.0 CDDL-1.1 CDLA-Permissive-2.0
CPAL-1.0 CPL-1.0 curl ECL-2.0 EFL-2.0 Elastic-2.0 EPL-1.0 EPL-2.0 EUPL-1.1 EUPL-1.2 GPL-1.0-or-later
GPL-2.0 GPL-2.0+ GPL-2.0-only GPL-2.0-or-later GPL-3.0 GPL-3.0+ GPL-3.0-only GPL-3.0-or-later HPND ICU
IJG Info-ZIP ISC JSON LGPL-2.0 LGPL-2.0-only LGPL-2.0-or-later LGPL-2.1 LGPL-2.1+ LGPL-2.1-only
LGPL-2.1-or-later LGPL-3.0 LGPL-3.0+ LGPL-3.0-only LGPL-3.0-or-later libpng-2.0 MIT MIT-0 MIT-CMU
MPL-1.1 MPL-2.0 MPL-2.0-no-copyleft-exception MS-PL MulanPSL-2.0 NCSA ODbL-1.0 OFL-1.1 OpenSSL OSL-3.0
PolyForm-Noncommercial-1.0.0 PolyForm-Small-Business-1.0.0 PostgreSQL PSF-2.0 Python-2.0 Python-2.0.1
RPL-1.5 Ruby SISSL SSPL-1.0 Unicode-3.0 Unicode-DFS-2015 Unicode-DFS-2016 Unlicense UPL-1.0 W3C
W3C-20150513 WTFPL X11 Zlib zlib-acknowledgement ZPL-2.0 ZPL-2.1
""".split()
)
KNOWN_UPPER = {x.upper() for x in KNOWN_IDS}
_CANONICAL = {x.upper(): x for x in KNOWN_IDS}


def canonical_spdx(text):
    """把合法的 SPDX 表达式统一写法（标识按官方大小写、运算符大写），不合法返回 None。"""
    try:
        tree = parse_spdx(text)
    except SpdxError:
        return None
    if not all(_looks_like_id(x) for x in spdx_ids(tree)):
        return None

    def fix(t):
        if t[0] == "id":
            return ("id", _CANONICAL.get(t[1].upper(), t[1]))
        if t[0] == "with":
            return ("with", _CANONICAL.get(t[1].upper(), t[1]), t[2])
        return (t[0], [fix(x) for x in t[1]])

    return render_spdx(fix(tree))


# 常见的非 SPDX 写法 → SPDX（键是小写、去掉多余空白后的文本）。
FREE_TEXT = {
    "mit license": "MIT",
    "the mit license": "MIT",
    "mit licence": "MIT",
    "mit/x11": "MIT",
    "expat": "MIT",
    "mit-style": "MIT",
    "apache 2.0": "Apache-2.0",
    "apache 2": "Apache-2.0",
    "apache-2": "Apache-2.0",
    "apache2": "Apache-2.0",
    "apache license 2.0": "Apache-2.0",
    "apache license, version 2.0": "Apache-2.0",
    "apache license version 2.0": "Apache-2.0",
    "apache software license": "Apache-2.0",
    "apache software license 2.0": "Apache-2.0",
    "asl 2.0": "Apache-2.0",
    "apache": "Apache-2.0",  # 不写版本的“Apache”（sqlite-vec 的 "MIT OR Apache"）；Apache 1.x 早就没人用了
    "bsd": "LicenseRef-BSD-Unspecified",
    "bsd license": "LicenseRef-BSD-Unspecified",
    "bsd-style": "LicenseRef-BSD-Unspecified",
    "new bsd": "BSD-3-Clause",
    "new bsd license": "BSD-3-Clause",
    "modified bsd license": "BSD-3-Clause",
    "3-clause bsd": "BSD-3-Clause",
    "3-clause bsd license": "BSD-3-Clause",
    "bsd 3-clause": "BSD-3-Clause",
    "bsd-3": "BSD-3-Clause",
    "simplified bsd": "BSD-2-Clause",
    "2-clause bsd": "BSD-2-Clause",
    "bsd 2-clause": "BSD-2-Clause",
    "bsd-2": "BSD-2-Clause",
    "isc license": "ISC",
    "isc license (iscl)": "ISC",
    "psf": "PSF-2.0",
    "psfl": "PSF-2.0",
    "psf license": "PSF-2.0",
    "python software foundation license": "PSF-2.0",
    "mpl 2.0": "MPL-2.0",
    "mpl-2": "MPL-2.0",
    "mozilla public license 2.0": "MPL-2.0",
    "mozilla public license 2.0 (mpl 2.0)": "MPL-2.0",
    "public domain": "LicenseRef-Public-Domain",
    "the unlicense": "Unlicense",
    "the unlicense (unlicense)": "Unlicense",
    "unlicensed": "LicenseRef-Unlicensed",
    "cc0": "CC0-1.0",
    "cc0 1.0": "CC0-1.0",
    "zlib/libpng": "Zlib",
    "boost": "BSL-1.0",
    "boost software license 1.0": "BSL-1.0",
    "lgpl": "LicenseRef-LGPL-Unspecified",
    "gpl": "LicenseRef-GPL-Unspecified",
    "agpl": "LicenseRef-AGPL-Unspecified",
    "proprietary": "LicenseRef-Proprietary",
    "commercial": "LicenseRef-Proprietary",
    "all rights reserved": "LicenseRef-Proprietary",
}

# PyPI 的 License 分类（Classifier: License :: ...）的最后一段 → SPDX。
CLASSIFIERS = {
    "mit license": "MIT",
    "mit no attribution license (mit-0)": "MIT-0",
    "apache software license": "Apache-2.0",
    "bsd license": "LicenseRef-BSD-Unspecified",
    "isc license (iscl)": "ISC",
    "python software foundation license": "PSF-2.0",
    "mozilla public license 2.0 (mpl 2.0)": "MPL-2.0",
    "mozilla public license 1.1 (mpl 1.1)": "MPL-1.1",
    "the unlicense (unlicense)": "Unlicense",
    "cc0 1.0 universal (cc0 1.0) public domain dedication": "CC0-1.0",
    "public domain": "LicenseRef-Public-Domain",
    "zope public license": "ZPL-2.1",
    "eclipse public license 2.0 (epl-2.0)": "EPL-2.0",
    "eclipse public license 1.0 (epl-1.0)": "EPL-1.0",
    "boost software license 1.0 (bsl-1.0)": "BSL-1.0",
    "universal permissive license (upl)": "UPL-1.0",
    "historical permission notice and disclaimer (hpnd)": "HPND",
    "artistic license": "Artistic-2.0",
    "academic free license (afl)": "AFL-3.0",
    "european union public licence 1.2 (eupl 1.2)": "EUPL-1.2",
    "european union public licence 1.1 (eupl 1.1)": "EUPL-1.1",
    "server side public license (sspl)": "SSPL-1.0",
    "gnu affero general public license v3": "AGPL-3.0-only",
    "gnu affero general public license v3 or later (agplv3+)": "AGPL-3.0-or-later",
    "gnu general public license v2 (gplv2)": "GPL-2.0-only",
    "gnu general public license v2 or later (gplv2+)": "GPL-2.0-or-later",
    "gnu general public license v3 (gplv3)": "GPL-3.0-only",
    "gnu general public license v3 or later (gplv3+)": "GPL-3.0-or-later",
    "gnu general public license (gpl)": "LicenseRef-GPL-Unspecified",
    "gnu lesser general public license v2 (lgplv2)": "LGPL-2.0-only",
    "gnu lesser general public license v2 or later (lgplv2+)": "LGPL-2.0-or-later",
    "gnu lesser general public license v3 (lgplv3)": "LGPL-3.0-only",
    "gnu lesser general public license v3 or later (lgplv3+)": "LGPL-3.0-or-later",
    "gnu library or lesser general public license (lgpl)": "LicenseRef-LGPL-Unspecified",
    "other/proprietary license": "LicenseRef-Proprietary",
    "freeware": "LicenseRef-Proprietary",
    "free for non-commercial use": "LicenseRef-NonCommercial",
}


def _norm_text(s):
    return re.sub(r"\s+", " ", s).strip().lower()


def normalize_declared(text):
    """把元数据里声明的许可证文本变成 SPDX 表达式；认不出返回 None。

    依次试：合法的 SPDX 表达式、Cargo 的旧写法 `MIT/Apache-2.0`、常见的自由文本写法。
    """
    if not text or not text.strip():
        return None
    text = text.strip()
    if text.startswith("(") and text.endswith(")") and "(" not in text[1:]:
        text = text[1:-1].strip()
    c = canonical_spdx(text)
    if c:
        return c
    key = _norm_text(text).rstrip(".")
    if key in FREE_TEXT:
        return FREE_TEXT[key]
    if "/" in text:  # Cargo 早期用 / 表示“任选其一”：`MIT/Apache-2.0`、`Apache-2.0 / MIT`
        c = canonical_spdx(" OR ".join(p.strip() for p in text.split("/")))
        if c:
            return c
    # “MIT OR Apache 2.0”这类混写：逐段换成 SPDX 再试一次。
    parts = re.split(r"\s+(and|or)\s+", text, flags=re.I)
    if len(parts) > 1:
        out = []
        for j, p in enumerate(parts):
            if j % 2:
                out.append(p.upper())
                continue
            sub = normalize_declared(p)
            if not sub:
                return None
            out.append("(%s)" % sub if " " in sub else sub)
        return canonical_spdx(" ".join(out))
    return None


# 从原文识别许可证。只认两种确定的写法，别的提法（比如 MPL-2.0 正文里定义“次级许可证”时提到 AGPL）不算：
# - 标题：许可证全文开头的名字，只在开头 TITLE_WINDOW 个字符里找；
# - 正文里固定的句子：各许可证授权条款本身的句子、或者源文件头部“按某许可证授权”的那句。
# 按顺序匹配，先匹配到的为准。
TITLE_WINDOW = 300
_TITLE_RULES = [
    ("MPL-2.0", ["mozilla public license", "2.0"]),
    ("SSPL-1.0", ["server side public license"]),
    ("BUSL-1.1", ["business source license"]),
    ("Elastic-2.0", ["elastic license 2.0"]),
    ("PolyForm-Noncommercial-1.0.0", ["polyform noncommercial license"]),
    ("AGPL-3.0-only", ["gnu affero general public license"]),
    ("LGPL-2.1-only", ["gnu lesser general public license", "version 2.1"]),
    ("LGPL-3.0-only", ["gnu lesser general public license"]),
    ("LGPL-2.0-only", ["gnu library general public license"]),
    ("GPL-3.0-only", ["gnu general public license", "version 3"]),
    ("GPL-2.0-only", ["gnu general public license", "version 2"]),
    ("EPL-2.0", ["eclipse public license", "2.0"]),
    ("EPL-1.0", ["eclipse public license", "1.0"]),
    ("CDDL-1.0", ["common development and distribution license"]),
    ("Apache-2.0", ["apache license", "version 2.0"]),
    ("BlueOak-1.0.0", ["blue oak model license"]),
    ("BSL-1.0", ["boost software license"]),
    ("Artistic-2.0", ["the artistic license 2.0"]),
    ("CC0-1.0", ["cc0 1.0 universal"]),
    ("CC-BY-4.0", ["creative commons attribution 4.0 international"]),
]
_BODY_RULES = [
    ("Apache-2.0", ["licensed under the apache license, version 2.0"]),
    ("MPL-2.0", ["subject to the terms of the mozilla public license, v. 2.0"]),
    ("AGPL-3.0-only", ["under the terms of the gnu affero general public license"]),
    ("LicenseRef-LGPL-Unspecified", ["under the terms of the gnu lesser general public license"]),
    ("LicenseRef-GPL-Unspecified", ["under the terms of the gnu general public license"]),
    ("Unlicense", ["this is free and unencumbered software released into the public domain"]),
    ("PSF-2.0", ["python software foundation license agreement"]),
    ("Zlib", ["altered source versions must be plainly marked as such"]),
    ("MIT-0", ["permission is hereby granted, free of charge, to any person obtaining a copy", "!the above copyright notice and this permission notice shall be included"]),
    ("MIT", ["permission is hereby granted, free of charge, to any person obtaining a copy"]),
    ("ISC", ["permission to use, copy, modify, and/or distribute this software for any purpose", "provided that the above copyright notice"]),
    ("ISC", ["permission to use, copy, modify, and distribute this software for any purpose", "provided that the above copyright notice"]),
    ("0BSD", ["permission to use, copy, modify, and/or distribute this software for any purpose"]),
    ("BSD-3-Clause", ["redistribution and use in source and binary forms", "endorse or promote products"]),
    ("BSD-2-Clause", ["redistribution and use in source and binary forms"]),
]


def _matches(t, needles):
    for n in needles:
        if n.startswith("!"):
            if n[1:] in t:
                return False
        elif n not in t:
            return False
    return True


def detect_text(text):
    """从许可证原文认出 SPDX 标识；认不出返回 None。"""
    t = _norm_text(text[:8000])
    # 去掉 Markdown 的标题符号、强调和引号差异，让关键句能对上。
    t = t.replace("*", "").replace("#", "").replace("“", '"').replace("”", '"').replace("’", "'").strip()
    head = t[:TITLE_WINDOW]
    for spdx, needles in _TITLE_RULES:
        if _matches(head, needles):
            return spdx
    for spdx, needles in _BODY_RULES:
        if _matches(t, needles):
            return spdx
    return None


# ---------------------------------------------------------------------------
# 原文文件

_LEGAL_NAME = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|UNLICENSE|COPYRIGHT|PATENTS|THIRD[-_ ]?PARTY|MIT-LICENSE|APACHE-LICENSE)", re.I)
_CODE_EXT = {
    ".js", ".cjs", ".mjs", ".ts", ".cts", ".mts", ".jsx", ".tsx", ".json", ".py", ".pyc", ".pyi", ".rs", ".go",
    ".map", ".sh", ".yml", ".yaml", ".toml", ".css", ".svg", ".png", ".jpg", ".gif", ".wasm", ".node", ".so",
    ".d", ".h", ".c", ".cc", ".cpp", ".java", ".rb",
}


def is_legal_file(name):
    if not _LEGAL_NAME.match(name):
        return False
    lower = name.lower()
    return not any(lower.endswith(ext) for ext in _CODE_EXT)


def legal_files(directory):
    """目录里（只看这一层）的许可证、NOTICE 文件，按名字排序。"""
    try:
        entries = sorted(os.scandir(directory), key=lambda e: e.name)
    except OSError:
        return []
    return [Path(e.path) for e in entries if is_legal_file(e.name) and e.is_file()]


def read_text(path):
    try:
        with open(path, "rb") as f:
            data = f.read(MAX_TEXT_BYTES + 1)
    except OSError:
        return None
    return data.decode("utf-8", errors="replace")


def is_notice(path):
    return Path(path).name.upper().startswith(("NOTICE", "THIRD"))


def license_from_files(paths):
    """从原文认许可证。NOTICE、第三方清单不参与（它们讲的是别人的许可证）。多个认出来的用 AND 连起来。"""
    found = []
    for p in paths:
        if is_notice(p):
            continue
        text = read_text(p)
        if text is None:
            continue
        spdx = detect_text(text)
        if spdx and spdx not in found:
            found.append(spdx)
    if not found:
        return None
    return found[0] if len(found) == 1 else " AND ".join(found)


# ---------------------------------------------------------------------------
# 清单

class Inventory:
    def __init__(self, out, subject):
        self.out = Path(out)
        self.subject = subject
        self.components = {}

    def add(self, ecosystem, name, version, declared, license, license_from, files, path, root_level=False, extra=None,
            authors=None):
        key = (ecosystem, name, version)
        if key in self.components:
            c = self.components[key]
            c["locations"] += 1
            c["root_level"] = c["root_level"] or root_level
            return c
        copied, digests = self._copy(ecosystem, name, version, files)
        c = {
            "ecosystem": ecosystem,
            "name": name,
            "version": version,
            "license": license,
            "declared": declared,
            "license_from": license_from,
            "files": copied,
            "text_sha256": digests,
            "generic_files": [] if copied or not license else self._generic(license),
            "authors": authors or None,
            "path": str(path) if path else None,
            "root_level": root_level,
            "locations": 1,
        }
        if extra:
            c.update(extra)
        self.components[key] = c
        return c

    def _generic(self, license):
        """许可证表达式里每个许可证的 SPDX 标准文本（有的话），复制到 texts/spdx/ 一份。"""
        try:
            ids = spdx_ids(parse_spdx(license))
        except SpdxError:
            return []
        out = []
        for lid in dict.fromkeys(ids):
            src = SPDX_DIR / ("%s.txt" % lid)
            if not src.is_file():
                continue
            rel = Path("texts") / "spdx" / src.name
            target = self.out / rel
            if not target.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, target)
            out.append(str(rel))
        return out

    def _copy(self, ecosystem, name, version, files):
        """原文按内容存：texts/by-hash/<哈希前 16 位>/<原文件名>。几百个 crate 的 LICENSE-APACHE 一字不差，只存一份。"""
        copied, digests = [], []
        for src in files or []:
            src = Path(src)
            try:
                size = src.stat().st_size
                data = src.read_bytes() if size <= MAX_TEXT_BYTES else None
            except OSError:
                continue
            if data is None:
                copied.append(str(src))  # 太大：只记原来的位置
                continue
            digest = hashlib.sha256(data).hexdigest()
            rel = Path("texts") / "by-hash" / digest[:16] / src.name
            target = self.out / rel
            if not target.is_file():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            copied.append(str(rel))
            digests.append(digest)
        return copied, digests

    def merge(self, other_dir):
        """并入另一个清单（比如 agent-shim 的 Rust crate 清单），原文一起复制过来。"""
        other_dir = Path(other_dir)
        data = json.loads((other_dir / "inventory.json").read_text(encoding="utf-8"))
        for c in data["components"]:
            key = (c["ecosystem"], c["name"], c["version"])
            if key in self.components:
                continue
            for f in c["files"] + c.get("generic_files", []):
                src = other_dir / f
                if not os.path.isabs(f) and src.is_file():
                    target = self.out / f
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(src, target)
            c = dict(c, merged_from=data.get("subject"))
            self.components[key] = c

    def write(self):
        self.out.mkdir(parents=True, exist_ok=True)
        comps = sorted(self.components.values(), key=lambda c: (c["ecosystem"], c["name"].lower(), c["version"]))
        doc = {"schema": SCHEMA, "subject": self.subject, "components": comps}
        (self.out / "inventory.json").write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        (self.out / "NOTICES.md").write_text(render_notices(doc), encoding="utf-8")
        return doc


def render_notices(doc):
    comps = doc["components"]
    lines = [
        "# 第三方组件许可证",
        "",
        "`%s` 里带的第三方组件和它们的许可证。原文在本目录的 `texts/` 下（Debian 包的在 `/usr/share/doc/<包>/copyright`）；"
        "机器可读的清单是 `inventory.json`。由 tools/licenses/licenses.py 生成。" % doc["subject"],
        "",
        "## 按许可证",
        "",
        "| 许可证 | 组件数 |",
        "|---|---|",
    ]
    counts = {}
    for c in comps:
        counts[c["license"] or "（未识别：%s）" % (c["declared"] or "无声明")] = counts.get(c["license"] or "（未识别：%s）" % (c["declared"] or "无声明"), 0) + 1
    for lic, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        lines.append("| %s | %d |" % (lic.replace("|", "\\|"), n))
    lines += [
        "",
        "## 组件",
        "",
        "包里没带原文的，列的是 SPDX 标准文本（`texts/spdx/`），版权方按包的元数据（作者）。",
        "",
        "| 生态 | 组件 | 版本 | 许可证 | 原文 |",
        "|---|---|---|---|---|",
    ]
    for c in comps:
        files = "、".join("`%s`" % f for f in c["files"])
        if not files and c.get("generic_files"):
            files = "标准文本 %s；版权方：%s" % ("、".join("`%s`" % f for f in c["generic_files"]), c.get("authors") or "包里没写")
        lic = c["license"] or "未识别（%s）" % (c["declared"] or "无声明")
        cells = (c["ecosystem"], c["name"], c["version"], lic, files or "—")
        lines.append("| %s |" % " | ".join(str(x).replace("|", "\\|").replace("\n", " ") for x in cells))
    return "\n".join(lines) + "\n"


_VAGUE = ("LicenseRef-BSD-Unspecified", "LicenseRef-LGPL-Unspecified", "LicenseRef-GPL-Unspecified", "LicenseRef-AGPL-Unspecified")


def resolve_license(declared_list, files, classifiers=()):
    """按可靠程度依次取：元数据里的声明（SPDX 表达式，或认得出的写法）、PyPI 的许可证分类、原文识别、
    含糊的声明或分类（“BSD”）。原文识别是猜的，有明确的元数据就不用它。"""
    declared_list = [d for d in declared_list if d and d.strip()]
    vague = None
    for d in declared_list:
        n = normalize_declared(d)
        if n and not any(v in n for v in _VAGUE):
            return n, "metadata"
        vague = vague or n
    specific = [c for c in classifiers if not any(v in c for v in _VAGUE)]
    if specific:
        # 几个分类是“任选其一”（python-dateutil：BSD 或 Apache），含糊的那个也留着。
        both = list(dict.fromkeys(classifiers))
        return (both[0] if len(both) == 1 else " OR ".join(both)), "classifier"
    from_text = license_from_files(files)
    if from_text:
        return from_text, "text"
    if vague:
        return vague, "metadata"
    if classifiers:
        return " OR ".join(dict.fromkeys(classifiers)), "classifier"
    return None, "none"


# ---------------------------------------------------------------------------
# npm

def npm_declared(pkg):
    lic = pkg.get("license")
    if isinstance(lic, dict):
        lic = lic.get("type")
    if isinstance(lic, str) and lic.strip():
        return lic.strip()
    lics = pkg.get("licenses")
    if isinstance(lics, list):
        names = [x.get("type") if isinstance(x, dict) else x for x in lics]
        names = [n for n in names if isinstance(n, str) and n.strip()]
        if names:
            return " OR ".join(names)
    if isinstance(lics, str) and lics.strip():
        return lics.strip()
    return None


def scan_npm(inv, root):
    """root 是一个 node_modules 目录（全局安装的是 /usr/local/lib/node_modules）。直接在它下面的包是顶层包。"""
    root = Path(root)
    if not root.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        here = Path(dirpath)
        dirnames.sort()
        parent = here.parent
        in_modules = parent.name == "node_modules" or (parent.name.startswith("@") and parent.parent.name == "node_modules")
        if "package.json" not in filenames or not in_modules or here.name.startswith("."):
            continue
        try:
            pkg = json.loads((here / "package.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        name, version = pkg.get("name"), pkg.get("version")
        if not isinstance(name, str) or not isinstance(version, str):
            continue
        declared = npm_declared(pkg)
        files = legal_files(here)
        if declared and declared.upper().startswith("SEE LICEN"):
            # “SEE LICENSE IN <文件>”：原文在包里指定的文件，可能不叫 LICENSE。
            ref = here / declared.split(" IN ", 1)[-1].strip() if " IN " in declared.upper() else None
            if ref and ref.is_file() and ref not in files:
                files.append(ref)
        license, source = resolve_license([declared] if declared else [], files)
        root_level = parent == root or (parent.parent == root and parent.name.startswith("@"))
        inv.add("npm", name, version, declared, license, source, files, here, root_level, authors=npm_author(pkg))


def npm_author(pkg):
    a = pkg.get("author")
    if isinstance(a, dict):
        a = a.get("name")
    return a.strip() if isinstance(a, str) and a.strip() else None


# ---------------------------------------------------------------------------
# Python

def pypi_norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def scan_python(inv, site_packages, root_names=()):
    """site_packages 是一个 site-packages 目录。root_names 是直接要求安装的包（清单 [install] 里的）。"""
    site_packages = Path(site_packages)
    roots = {pypi_norm(n) for n in root_names}
    for dist in sorted(site_packages.glob("*.dist-info")):
        meta_path = dist / "METADATA"
        if not meta_path.is_file():
            continue
        msg = email.parser.HeaderParser().parsestr(meta_path.read_text(encoding="utf-8", errors="replace"))
        name, version = msg.get("Name"), msg.get("Version")
        if not name or not version:
            continue
        declared = []
        expr = msg.get("License-Expression")
        if expr:
            declared.append(expr.strip())
        lic = msg.get("License")
        # 有的包把整篇许可证正文塞进 License 字段：太长或多行的不当声明用，靠原文识别。
        short_lic = lic.strip() if lic and len(lic.strip()) <= 120 and "\n" not in lic.strip() else None
        if short_lic and short_lic.upper() not in ("UNKNOWN", "NONE"):
            declared.append(short_lic)
        classifiers = [c.split("::")[-1].strip() for c in msg.get_all("Classifier") or [] if c.startswith("License ::")]
        mapped = [CLASSIFIERS.get(c.lower()) for c in classifiers]
        mapped = [m for m in mapped if m and m != "LicenseRef-OSI-Approved"]
        files = legal_files(dist)
        for lf in msg.get_all("License-File") or []:
            for cand in (dist / "licenses" / lf, dist / lf):
                if cand.is_file() and cand not in files:
                    files.append(cand)
        lic_dir = dist / "licenses"
        if lic_dir.is_dir():
            for p in sorted(lic_dir.rglob("*")):
                if p.is_file() and p not in files:
                    files.append(p)
        license, source = resolve_license(declared, files, mapped)
        shown = "; ".join(declared + ["Classifier: %s" % c for c in classifiers]) or None
        authors = msg.get("Author") or msg.get("Author-email") or msg.get("Maintainer") or msg.get("Maintainer-email")
        inv.add("pypi", name, version, shown, license, source, files, dist, pypi_norm(name) in roots,
                authors=authors.strip() if authors and authors.strip().upper() != "UNKNOWN" else None)


# ---------------------------------------------------------------------------
# Debian

_DEP5_LICENSE = re.compile(r"^License:\s*(.+?)\s*$", re.M)


def scan_deb(inv, admindir=None):
    """dpkg 装的包。原文就在 /usr/share/doc/<包>/copyright，不复制，只记位置和 DEP-5 格式里声明的许可证名。"""
    cmd = ["dpkg-query", "-W", "-f", "${Package}\t${Version}\t${Status}\n"]
    if admindir:
        cmd.insert(1, "--admindir=%s" % admindir)
    try:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 3 or not parts[2].endswith(" installed"):
            continue
        name, version = parts[0], parts[1]
        name_noarch = name.split(":", 1)[0]
        copyright = Path("/usr/share/doc") / name_noarch / "copyright"
        declared = None
        if copyright.is_file():
            text = read_text(copyright) or ""
            names = []
            for m in _DEP5_LICENSE.finditer(text):
                for n in re.split(r"\s+(?:or|and)\s+|,\s*", m.group(1)):
                    n = n.strip()
                    if n and n not in names and len(n) < 60:
                        names.append(n)
            declared = ", ".join(names) or None
        inv.components.setdefault(
            ("deb", name_noarch, version),
            {
                "ecosystem": "deb",
                "name": name_noarch,
                "version": version,
                "license": None,
                "declared": declared,
                "license_from": "dep5" if declared else "none",
                "files": [str(copyright)] if copyright.is_file() else [],
                "text_sha256": [],
                "path": None,
                "root_level": False,
                "locations": 1,
            },
        )


# ---------------------------------------------------------------------------
# 额外的原文（上游有、装好的包里没带的，比如 Codex 的 NOTICE）

def scan_extra(inv, directory):
    """directory 下有 sources.toml，每个 [[file]] 写明 component、version、license、path（相对 directory）、url。

    顶层的 applies_to 写这些原文是按哪个包的哪个版本核对的（"<生态>:<包名>@<版本>"），检查时镜像里没有这个
    版本就报错：上游升级后要重新核对原文。
    """
    directory = Path(directory)
    meta = directory / "sources.toml"
    if not meta.is_file():
        return
    data = tomllib.loads(meta.read_text(encoding="utf-8"))
    applies_to = data.get("applies_to", [])
    groups = {}
    for f in data.get("file", []):
        key = (f["component"], f["version"])
        groups.setdefault(key, {"license": f["license"], "files": [], "urls": []})
        groups[key]["files"].append(directory / f["path"])
        groups[key]["urls"].append(f.get("url"))
    for (name, version), g in groups.items():
        missing = [str(p) for p in g["files"] if not p.is_file()]
        if missing:
            raise SystemExit("extra 原文缺文件：%s" % ", ".join(missing))
        inv.add("upstream", name, version, g["license"], canonical_spdx(g["license"]) or g["license"], "extra", g["files"], None,
                extra={"urls": [u for u in g["urls"] if u], "applies_to": applies_to, "notices_dir": directory.name})


def scan_runtime_node(inv):
    """Node.js 本身（基础镜像带的）。官方镜像不带 Node 的 LICENSE（里面还列了 Node 打包进去的 V8、OpenSSL、ICU 等的许可证），
    按镜像里 Node 的确切版本从上游取一份；取不到构建就失败，不悄悄漏掉。"""
    try:
        version = subprocess.run(["node", "--version"], check=True, capture_output=True, text=True).stdout.strip().lstrip("v")
    except (OSError, subprocess.CalledProcessError):
        return
    files = [p for p in (Path("/usr/local/share/doc/node/LICENSE"), Path("/usr/local/include/node/LICENSE")) if p.is_file()]
    urls = []
    tmp = None
    if not files:
        url = NODE_LICENSE_URL % version
        tmp = Path(tempfile.mkdtemp()) / "LICENSE"
        tmp.write_bytes(fetch(url))
        files, urls = [tmp], [url]
    inv.add("runtime", "node", version, "MIT", "MIT", "metadata", files, shutil.which("node"), extra={"urls": urls} if urls else None,
            authors="Node.js contributors")
    if tmp:
        shutil.rmtree(tmp.parent, ignore_errors=True)


def fetch(url, attempts=4):
    import time
    import urllib.request

    for i in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return r.read()
        except OSError as e:
            if i == attempts - 1:
                raise SystemExit("取不到 %s：%s" % (url, e))
            time.sleep(2 ** (i + 1))


# ---------------------------------------------------------------------------
# Cargo

def scan_cargo(inv, packages, target=None, manifest_path=None, metadata_json=None):
    """packages 是工作区里程序的包名；列出它们在 target 平台上的运行时依赖（不含 dev 依赖和只在构建时用的依赖）。"""
    if metadata_json:
        meta = json.loads(Path(metadata_json).read_text(encoding="utf-8"))
    else:
        cmd = ["cargo", "metadata", "--format-version", "1", "--locked"]
        if manifest_path:
            cmd += ["--manifest-path", str(manifest_path)]
        if target:
            cmd += ["--filter-platform", target]
        meta = json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True).stdout)
    by_id = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    workspace = set(meta["workspace_members"])
    wanted = [pid for pid in workspace if by_id[pid]["name"] in packages]
    missing = set(packages) - {by_id[p]["name"] for p in wanted}
    if missing:
        raise SystemExit("工作区里没有这些包：%s" % ", ".join(sorted(missing)))
    seen, stack = set(), list(wanted)
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        for dep in nodes[pid]["deps"]:
            kinds = [k.get("kind") for k in dep.get("dep_kinds", [])]
            if any(k is None for k in kinds):  # 普通依赖（会编进程序的）
                stack.append(dep["pkg"])
    for pid in sorted(seen - workspace, key=lambda p: (by_id[p]["name"], by_id[p]["version"])):
        p = by_id[pid]
        src_dir = Path(p["manifest_path"]).parent
        files = legal_files(src_dir)
        if p.get("license_file"):
            lf = src_dir / p["license_file"]
            if lf.is_file() and lf not in files:
                files.append(lf)
        declared = p.get("license")
        license, source = resolve_license([declared] if declared else [], files)
        inv.add("cargo", p["name"], p["version"], declared or (p.get("license_file") and "license-file: %s" % p["license_file"]),
                license, source, files, None, root_level=False, authors=", ".join(p.get("authors") or []) or None)


# ---------------------------------------------------------------------------
# 策略检查

class Policy:
    def __init__(self, data):
        self.allow = data.get("allow", [])
        self.deny = data.get("deny", [])
        self.ecosystems = data.get("ecosystem", {})
        self.exceptions = data.get("exception", [])
        self.agents = data.get("agents", {})
        for i, e in enumerate(self.exceptions):
            for k in ("ecosystem", "name", "license", "reason"):
                if not e.get(k):
                    raise SystemExit("policy: 第 %d 个 [[exception]] 缺 %s" % (i + 1, k))

    @classmethod
    def load(cls, path):
        return cls(tomllib.loads(Path(path).read_text(encoding="utf-8")))

    def classify_id(self, lid, ecosystem):
        eco = self.ecosystems.get(ecosystem, {})
        if any(fnmatch.fnmatchcase(lid.upper(), pat.upper()) for pat in self.deny + eco.get("deny", [])):
            return "deny"
        if any(fnmatch.fnmatchcase(lid.upper(), pat.upper()) for pat in eco.get("review", [])):
            return "review"
        if any(fnmatch.fnmatchcase(lid.upper(), pat.upper()) for pat in self.allow + eco.get("allow", [])):
            return "allow"
        return "review"

    def classify(self, expr, ecosystem):
        """allow / review（要登记）/ deny。OR 取最有利的一支，AND 取最严的。"""
        rank = {"allow": 0, "review": 1, "deny": 2}
        try:
            tree = parse_spdx(expr)
        except SpdxError:
            return "review"

        def walk(t):
            if t[0] in ("id", "with"):
                return self.classify_id(t[1], ecosystem)
            results = [walk(x) for x in t[1]]
            pick = min if t[0] == "or" else max
            return pick(results, key=rank.get)

        return walk(tree)

    def exception_for(self, c):
        shown = c["license"] or c["declared"] or ""
        for e in self.exceptions:
            if e["ecosystem"] != c["ecosystem"] or not fnmatch.fnmatchcase(c["name"], e["name"]):
                continue
            if not fnmatch.fnmatchcase(c["version"], e.get("version", "*")):
                continue
            if e["license"] != shown:
                continue
            if e.get("text_sha256") and e["text_sha256"] not in (c.get("text_sha256") or []):
                continue
            return e
        return None


def check(inventory, policy, manifest=None, out=sys.stdout):
    """返回 (错误列表, 警告列表, 汇总的 Markdown)。"""
    errors, warnings, registered = [], [], []
    comps = inventory["components"]
    for c in comps:
        label = "%s %s@%s" % (c["ecosystem"], c["name"], c["version"])
        eco = policy.ecosystems.get(c["ecosystem"], {})
        if eco.get("mode") == "deny-only":
            # Debian main 都是自由软件；只拦明确禁止的（DEP-5 里声明的许可证名）。
            for n in re.split(r",\s*", c["declared"] or ""):
                spdx = normalize_declared(n) or n
                if n and any(fnmatch.fnmatchcase(spdx.upper(), pat.upper()) for pat in policy.deny):
                    errors.append("%s：许可证 %s 在禁止名单里" % (label, n))
            continue
        exc = policy.exception_for(c)
        if exc:
            registered.append((c, exc))
            continue
        if c["license"] is None:
            errors.append("%s：认不出许可证（声明：%s）。查清后在 policy.toml 登记，见 docs/licenses.md" % (label, c["declared"] or "无"))
            continue
        verdict = policy.classify(c["license"], c["ecosystem"])
        if verdict == "deny":
            errors.append("%s：许可证 %s 在禁止名单里（网络 copyleft 或限制商用、托管）" % (label, c["license"]))
        elif verdict == "review":
            errors.append("%s：许可证 %s 需要单独审查，确认能用后在 policy.toml 的 [[exception]] 登记" % (label, c["license"]))
        if not c["files"] and not c.get("generic_files") and c["ecosystem"] != "deb":
            warnings.append(label)

    present = {"%s:%s@%s" % (c["ecosystem"], c["name"], c["version"]) for c in comps}
    stale = {}
    for c in comps:
        for ref in c.get("applies_to") or []:
            if ref not in present:
                stale.setdefault((c.get("notices_dir"), ref), True)
    for d, ref in stale:
        errors.append("deploy/templates/notices/%s 的原文是按 %s 核对的，镜像里没有这个版本：上游升级了，"
                      "按 docs/licenses.md 重新核对原文后更新 sources.toml" % (d, ref))

    unused = [e for e in policy.exceptions if e.get("agents") and manifest and manifest["agent"]["id"] in e["agents"]
              and not any(x is e for _, x in registered)]
    for e in unused:
        errors.append("policy.toml 登记的 %s %s（%s）在清单里没找到：上游换了包名或许可证？复核后更新登记" % (e["ecosystem"], e["name"], e["license"]))

    if manifest:
        errors += check_manifest(inventory, policy, manifest)

    summary = render_summary(inventory, errors, warnings, registered)
    return errors, warnings, summary


def _license_shown(c, policy):
    exc = policy.exception_for(c)
    if exc and exc.get("as"):
        return exc["as"]
    return c["license"] or c["declared"]


def check_manifest(inventory, policy, manifest):
    """清单 [install] 里的包都在镜像里；清单写的 agent.license 和 policy.toml 指定的那个包的许可证一致。"""
    errors = []
    agent = manifest["agent"]["id"]
    comps = inventory["components"]
    inst = manifest.get("install", {})
    wanted = []
    for spec in inst.get("npm", []):
        at = spec.rindex("@", 1)
        wanted.append(("npm", spec[:at], spec[at + 1:]))
    for spec in inst.get("pip", []):
        name, version = spec.split("==", 1)
        wanted.append(("pypi", pypi_norm(name.split("[", 1)[0]), version))
    for eco, name, version in wanted:
        hit = [c for c in comps if c["ecosystem"] == eco and (pypi_norm(c["name"]) if eco == "pypi" else c["name"]) == name and c["root_level"]]
        if not hit:
            errors.append("清单 [install] 的 %s %s 不在镜像里" % (eco, name))
        elif not any(c["version"] == version for c in hit):
            errors.append("清单 [install] 锁定 %s %s@%s，镜像里是 %s" % (eco, name, version, ", ".join(c["version"] for c in hit)))
    rule = policy.agents.get(agent)
    if not rule:
        errors.append("policy.toml 没有 [agents.%s]：要写明 agent.license 对应哪个包" % agent)
        return errors
    eco, name = rule["license_of"].split(":", 1)
    hit = [c for c in comps if c["ecosystem"] == eco and c["name"] == name]
    if not hit:
        errors.append("[agents.%s] license_of 指的 %s 不在镜像里" % (agent, rule["license_of"]))
        return errors
    shown = _license_shown(hit[0], policy)
    if shown != manifest["agent"]["license"]:
        errors.append(
            "清单 agent.license 是 %s，但 %s 的许可证是 %s：上游改了许可证？复核后改清单（App 的目录里显示的是清单写的）"
            % (manifest["agent"]["license"], rule["license_of"], shown)
        )
    return errors


def render_summary(inventory, errors, warnings, registered):
    comps = inventory["components"]
    by_eco = {}
    for c in comps:
        by_eco[c["ecosystem"]] = by_eco.get(c["ecosystem"], 0) + 1
    lines = [
        "### 许可证：%s" % inventory["subject"],
        "",
        "%d 个组件（%s）。%s" % (
            len(comps),
            "、".join("%s %d" % kv for kv in sorted(by_eco.items())),
            "**%d 个问题**" % len(errors) if errors else "符合策略",
        ),
        "",
    ]
    if errors:
        lines += ["问题：", ""] + ["- %s" % e for e in errors] + [""]
    if registered:
        lines += ["登记过的例外：", ""]
        for c, e in registered:
            lines.append("- %s %s@%s：%s（%s）" % (c["ecosystem"], c["name"], c["version"], e.get("as") or e["license"], e["reason"]))
        lines.append("")
    generic = [c for c in comps if not c["files"] and c.get("generic_files")]
    if generic:
        lines.append("%d 个包没带许可证原文，用的是 SPDX 标准文本加元数据里的作者。" % len(generic))
        lines.append("")
    if warnings:
        lines.append("%d 个包既没带原文、也没有对应的标准文本（tools/licenses/spdx/），例如：%s" % (len(warnings), "、".join(warnings[:5])))
        lines.append("")
    return "\n".join(lines)


def esc_data(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def esc_prop(s):
    return esc_data(s).replace(":", "%3A").replace(",", "%2C")


# ---------------------------------------------------------------------------
# 命令行

def cmd_scan(args):
    inv = Inventory(args.out, args.subject)
    root_names = []
    if args.manifest:
        m = tomllib.loads(Path(args.manifest).read_text(encoding="utf-8"))
        root_names = [s.split("==", 1)[0].split("[", 1)[0] for s in m.get("install", {}).get("pip", [])]
    for root in args.npm_root or []:
        scan_npm(inv, root)
    for sp in args.site_packages or []:
        for path in sorted(Path("/").glob(sp.lstrip("/"))) if any(ch in sp for ch in "*?[") else [Path(sp)]:
            scan_python(inv, path, root_names)
    if args.deb:
        scan_deb(inv)
    if args.node:
        scan_runtime_node(inv)
    for d in args.extra or []:
        scan_extra(inv, d)
    for d in args.merge or []:
        inv.merge(d)
    doc = inv.write()
    print("%s：%d 个组件 → %s" % (args.subject, len(doc["components"]), args.out), file=sys.stderr)


def cmd_cargo(args):
    inv = Inventory(args.out, args.subject or "+".join(args.package))
    scan_cargo(inv, args.package, target=args.target, manifest_path=args.manifest_path, metadata_json=args.metadata)
    doc = inv.write()
    print("%s：%d 个 crate → %s" % (inv.subject, len(doc["components"]), args.out), file=sys.stderr)


def cmd_check(args):
    inventory = json.loads(Path(args.inventory).read_text(encoding="utf-8"))
    policy = Policy.load(args.policy)
    manifest = tomllib.loads(Path(args.manifest).read_text(encoding="utf-8")) if args.manifest else None
    errors, warnings, summary = check(inventory, policy, manifest)
    print(summary)
    actions = os.environ.get("GITHUB_ACTIONS") == "true"
    if actions:
        file = args.manifest or str(args.policy)
        for e in errors[:MAX_ANNOTATIONS]:
            print("::error file=%s,title=%s::%s" % (esc_prop(file), esc_prop("许可证：" + inventory["subject"]), esc_data(e)))
        if len(errors) > MAX_ANNOTATIONS:
            print("::error title=%s::还有 %d 个问题，见运行摘要" % (esc_prop("许可证：" + inventory["subject"]), len(errors) - MAX_ANNOTATIONS))
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
                f.write(summary + "\n")
    return 1 if errors else 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="扫描装好的包，写清单")
    s.add_argument("--out", required=True)
    s.add_argument("--subject", required=True, help="清单说的是什么，比如 agents/claude:0.90.0")
    s.add_argument("--npm-root", action="append", help="node_modules 目录，可给多个")
    s.add_argument("--site-packages", action="append", help="site-packages 目录，可以用通配符")
    s.add_argument("--manifest", help="agent 清单（用来认 [install] 里直接装的 Python 包）")
    s.add_argument("--deb", action="store_true", help="扫描 dpkg 装的包")
    s.add_argument("--node", action="store_true", help="记下 Node.js 本身")
    s.add_argument("--extra", action="append", help="额外原文的目录（里面有 sources.toml）")
    s.add_argument("--merge", action="append", help="并入另一个清单目录（比如 agent-shim 的 crate 清单）")
    s.set_defaults(func=cmd_scan)

    c = sub.add_parser("cargo", help="列出工作区程序依赖的 crate，写清单")
    c.add_argument("--out", required=True)
    c.add_argument("--subject")
    c.add_argument("-p", "--package", action="append", required=True, help="工作区里的程序包名，可给多个")
    c.add_argument("--target", help="只算这个平台上的依赖，比如 x86_64-unknown-linux-gnu；不给就算全部平台")
    c.add_argument("--manifest-path")
    c.add_argument("--metadata", help=argparse.SUPPRESS)  # 测试用：直接给 cargo metadata 的输出
    c.set_defaults(func=cmd_cargo)

    k = sub.add_parser("check", help="按策略检查清单")
    k.add_argument("inventory")
    k.add_argument("--policy", default=str(Path(__file__).with_name("policy.toml")))
    k.add_argument("--manifest", help="agent 清单：再核对 [install] 和 agent.license")
    k.set_defaults(func=cmd_check)

    t = sub.add_parser("self-test", help="内置测试")
    t.set_defaults(func=lambda a: self_test())

    args = p.parse_args(argv)
    return args.func(args) or 0


# ---------------------------------------------------------------------------
# 测试

MIT_TEXT = """MIT License

Copyright (c) 2024 Someone

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
"""

APACHE_TEXT = """
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/
"""

BSD3_TEXT = """Copyright (c) 2010, Someone. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
* Neither the name of the copyright holder nor the names of its contributors
  may be used to endorse or promote products derived from this software
  without specific prior written permission.
"""

ISC_TEXT = """ISC License

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.
"""

ZERO_BSD_TEXT = """Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
"""

AGPL_TEXT = """                    GNU AFFERO GENERAL PUBLIC LICENSE
                       Version 3, 19 November 2007
"""

MPL_TEXT = """Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.
"""

PROPRIETARY_TEXT = """© Anthropic PBC. All rights reserved. Use is subject to the Legal Agreements outlined here: https://example.com/legal.
"""

TEST_POLICY = """
allow = ["MIT", "Apache-2.0", "BSD-*", "ISC", "0BSD", "LGPL-*", "MPL-2.0", "LicenseRef-BSD-Unspecified"]
deny = ["AGPL-*", "SSPL-*", "BUSL-*"]

[ecosystem.cargo]
review = ["LGPL-*"]

[ecosystem.deb]
mode = "deny-only"

[[exception]]
ecosystem = "npm"
name = "@vendor/sdk"
version = "1.*"
license = "SEE LICENSE IN README.md"
as = "LicenseRef-Vendor-Commercial"
reason = "专有，法务确认过"
agents = ["demo"]

[agents.demo]
license_of = "npm:@vendor/sdk"
"""


def self_test():
    failures = []

    def eq(got, want, what):
        if got != want:
            failures.append("%s：得到 %r，应该是 %r" % (what, got, want))

    # SPDX 解析和规范化
    eq(canonical_spdx("MIT"), "MIT", "单个标识")
    eq(canonical_spdx("mit or apache-2.0"), "MIT OR Apache-2.0", "小写运算符和标识")
    eq(canonical_spdx("(MIT OR Apache-2.0) AND Unicode-3.0"), "(MIT OR Apache-2.0) AND Unicode-3.0", "括号")
    eq(canonical_spdx("Apache-2.0 WITH LLVM-exception"), "Apache-2.0 WITH LLVM-exception", "WITH")
    eq(canonical_spdx("MIT License"), None, "自由文本不是 SPDX")
    eq(canonical_spdx("(MIT"), None, "括号不配对")
    eq(canonical_spdx("MIT AND"), None, "表达式不完整")
    eq(canonical_spdx("LicenseRef-Foo"), "LicenseRef-Foo", "LicenseRef")
    eq(normalize_declared("MIT/Apache-2.0"), "MIT OR Apache-2.0", "Cargo 的旧写法")
    eq(normalize_declared("Apache-2.0 / MIT"), "Apache-2.0 OR MIT", "Cargo 的旧写法（带空格）")
    eq(normalize_declared("mit/x11"), "MIT", "MIT/X11 不是两个许可证")
    eq(normalize_declared("Apache License, Version 2.0"), "Apache-2.0", "自由文本")
    eq(normalize_declared("(MIT)"), "MIT", "整个包在括号里")
    eq(normalize_declared("MIT or Apache 2.0"), "MIT OR Apache-2.0", "混写")
    eq(normalize_declared("BSD"), "LicenseRef-BSD-Unspecified", "含糊的 BSD")
    eq(normalize_declared("SEE LICENSE IN LICENSE.md"), None, "SEE LICENSE IN 认不出")
    eq(normalize_declared(""), None, "空")

    # 原文识别
    eq(detect_text(MIT_TEXT), "MIT", "MIT 原文")
    eq(detect_text(APACHE_TEXT), "Apache-2.0", "Apache 原文")
    eq(detect_text(BSD3_TEXT), "BSD-3-Clause", "BSD-3 原文")
    eq(detect_text(ISC_TEXT), "ISC", "ISC 原文")
    eq(detect_text(ZERO_BSD_TEXT), "0BSD", "0BSD 原文")
    eq(detect_text(AGPL_TEXT), "AGPL-3.0-only", "AGPL 原文")
    eq(detect_text(PROPRIETARY_TEXT), None, "专有声明认不出")
    eq(detect_text(MPL_TEXT), "MPL-2.0", "MPL-2.0 正文里提到 AGPL 不算 AGPL")
    eq(detect_text("Copyright 2020 X\n\nLicensed under the Apache License, Version 2.0 (the \"License\");"), "Apache-2.0", "Apache 头部声明")
    eq(detect_text("# MIT License\n\n" + MIT_TEXT), "MIT", "Markdown 标题")
    eq(detect_text("Some notice. This product includes software under the GNU General Public License."), None, "顺带提到 GPL 不算")
    eq(is_legal_file("LICENSE"), True, "LICENSE")
    eq(is_legal_file("LICENSE-APACHE"), True, "LICENSE-APACHE")
    eq(is_legal_file("license.md"), True, "license.md")
    eq(is_legal_file("NOTICE.txt"), True, "NOTICE.txt")
    eq(is_legal_file("license.js"), False, "代码文件不算")
    eq(is_legal_file("README.md"), False, "README 不算")

    # 策略判定
    pol = Policy(tomllib.loads(TEST_POLICY))
    eq(pol.classify("MIT", "npm"), "allow", "放行")
    eq(pol.classify("AGPL-3.0-only", "npm"), "deny", "禁止")
    eq(pol.classify("MIT OR AGPL-3.0-only", "npm"), "allow", "OR 取有利的")
    eq(pol.classify("MIT AND AGPL-3.0-only", "npm"), "deny", "AND 取最严的")
    eq(pol.classify("GPL-3.0-only", "npm"), "review", "GPL 要登记")
    eq(pol.classify("GPL-2.0-only OR MIT", "npm"), "allow", "GPL 或 MIT")
    eq(pol.classify("LGPL-3.0-only", "npm"), "allow", "LGPL 在 npm 放行")
    eq(pol.classify("LGPL-3.0-only", "cargo"), "review", "LGPL 在 cargo 要登记（静态链接）")
    eq(pol.classify("Apache-2.0 WITH LLVM-exception", "cargo"), "allow", "WITH 按主许可证")
    eq(pol.classify("not spdx", "npm"), "review", "解析不了的要登记")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        # npm：顶层包、带 scope 的包、嵌套的包、包里非包的 package.json、各种 license 字段写法
        nm = tmp / "node_modules"

        def pkg(path, data, files=None):
            path.mkdir(parents=True, exist_ok=True)
            (path / "package.json").write_text(json.dumps(data))
            for name, text in (files or {}).items():
                (path / name).write_text(text)

        pkg(nm / "a", {"name": "a", "version": "1.0.0", "license": "MIT"}, {"LICENSE": MIT_TEXT})
        pkg(nm / "a" / "lib", {"type": "module"})
        pkg(nm / "a" / "node_modules" / "b", {"name": "b", "version": "2.0.0", "license": {"type": "ISC"}, "author": {"name": "Bea"}})
        pkg(nm / "a" / "node_modules" / "c", {"name": "c", "version": "0.1.0", "licenses": [{"type": "MIT"}, {"type": "Apache-2.0"}]})
        pkg(nm / "@vendor" / "sdk", {"name": "@vendor/sdk", "version": "1.2.0", "license": "SEE LICENSE IN README.md"},
            {"LICENSE.md": PROPRIETARY_TEXT, "README.md": "readme"})
        pkg(nm / "d", {"name": "d", "version": "3.0.0"}, {"LICENSE.txt": BSD3_TEXT})
        pkg(nm / "e", {"name": "e", "version": "1.0.0", "license": "AGPL-3.0"})
        pkg(nm / "f", {"name": "f", "version": "1.0.0", "license": "Apache 2.0"}, {"NOTICE": "Copyright f"})
        pkg(nm / "g", {"name": "g", "version": "1.0.0", "license": "MIT"}, {"license.js": "code"})
        pkg(nm / "a" / "node_modules" / "d", {"name": "d", "version": "3.0.0"}, {"LICENSE.txt": BSD3_TEXT})

        out = tmp / "out"
        inv = Inventory(out, "test")
        scan_npm(inv, nm)
        got = {c["name"]: c for c in inv.components.values()}
        eq(sorted(got), ["@vendor/sdk", "a", "b", "c", "d", "e", "f", "g"], "npm 包")
        eq(got["a"]["license"], "MIT", "npm license 字符串")
        eq(got["a"]["root_level"], True, "顶层包")
        eq(got["b"]["license"], "ISC", "npm license 对象")
        eq(got["b"]["root_level"], False, "嵌套的不是顶层")
        eq(got["b"]["generic_files"], ["texts/spdx/ISC.txt"] if (SPDX_DIR / "ISC.txt").is_file() else [], "没带原文用标准文本")
        eq(got["b"]["authors"], "Bea", "npm 作者")
        eq(got["a"]["generic_files"], [], "带了原文就不用标准文本")
        eq(got["c"]["license"], "MIT OR Apache-2.0", "npm licenses 数组")
        eq(got["@vendor/sdk"]["license"], None, "专有的认不出")
        eq(got["@vendor/sdk"]["root_level"], True, "带 scope 的顶层包")
        eq(sorted(Path(f).name for f in got["@vendor/sdk"]["files"]), ["LICENSE.md", "README.md"], "SEE LICENSE IN 指的文件")
        eq(got["d"]["license"], "BSD-3-Clause", "没声明时看原文")
        eq(got["d"]["license_from"], "text", "来源是原文")
        eq(got["d"]["locations"], 2, "同名同版本只记一次")
        eq(got["e"]["license"], "AGPL-3.0", "AGPL")
        eq(got["f"]["license"], "Apache-2.0", "自由文本声明")
        eq([Path(f).name for f in got["f"]["files"]], ["NOTICE"], "NOTICE 复制")
        eq(got["g"]["files"], [], "代码文件不当原文")
        eq((out / got["a"]["files"][0]).read_text(), MIT_TEXT, "原文复制到 texts/")

        # Python：License-Expression、分类、原文、整篇正文塞进 License 字段
        sp = tmp / "site-packages"

        def dist(name, version, headers, files=None, licenses_dir=None):
            d = sp / ("%s-%s.dist-info" % (name.replace("-", "_"), version))
            d.mkdir(parents=True)
            body = "Metadata-Version: 2.4\nName: %s\nVersion: %s\n" % (name, version) + "".join("%s: %s\n" % h for h in headers)
            (d / "METADATA").write_text(body + "\nlong description\n")
            for fname, text in (files or {}).items():
                (d / fname).write_text(text)
            for fname, text in (licenses_dir or {}).items():
                (d / "licenses").mkdir(exist_ok=True)
                (d / "licenses" / fname).write_text(text)

        dist("hermes-agent", "0.19.0", [("License-Expression", "MIT"), ("License-File", "LICENSE")], licenses_dir={"LICENSE": MIT_TEXT})
        dist("old-style", "1.0", [("License", "BSD"), ("Classifier", "License :: OSI Approved :: BSD License")], {"LICENSE.txt": BSD3_TEXT})
        dist("classified", "2.0", [("Classifier", "License :: OSI Approved :: Apache Software License")])
        dist("text-in-field", "1.0", [("License", MIT_TEXT.replace("\n", "\n        "))], {"LICENSE": MIT_TEXT})
        dist("dual", "1.0", [("Classifier", "License :: OSI Approved :: MIT License"), ("Classifier", "License :: OSI Approved :: Apache Software License")])
        dist("unknown", "1.0", [("License", "UNKNOWN")])
        dist("dateutil", "2.9.0", [("License", "Dual License"), ("Classifier", "License :: OSI Approved :: BSD License"),
                                   ("Classifier", "License :: OSI Approved :: Apache Software License")])
        dist("pathspec", "1.1.1", [("Classifier", "License :: OSI Approved :: Mozilla Public License 2.0 (MPL 2.0)"), ("License-File", "LICENSE")],
             licenses_dir={"LICENSE": MPL_TEXT})
        inv = Inventory(out, "test")
        scan_python(inv, sp, ["hermes-agent"])
        got = {c["name"]: c for c in inv.components.values()}
        eq(got["hermes-agent"]["license"], "MIT", "License-Expression")
        eq(got["hermes-agent"]["root_level"], True, "直接装的包")
        eq([Path(f).name for f in got["hermes-agent"]["files"]], ["LICENSE"], "licenses/ 下的原文")
        eq(got["old-style"]["license"], "BSD-3-Clause", "含糊的声明看原文")
        eq(got["classified"]["license"], "Apache-2.0", "只有分类")
        eq(got["text-in-field"]["license"], "MIT", "正文塞进 License 字段")
        eq(got["dual"]["license"], "MIT OR Apache-2.0", "两个分类")
        eq(got["unknown"]["license"], None, "UNKNOWN")
        eq((got["pathspec"]["license"], got["pathspec"]["license_from"]), ("MPL-2.0", "classifier"), "明确的分类比原文识别优先")
        eq(got["dateutil"]["license"], "LicenseRef-BSD-Unspecified OR Apache-2.0", "含糊的分类在“任选其一”里留着")

        # extra 原文
        ex = tmp / "extra"
        ex.mkdir()
        (ex / "NOTICE").write_text("Copyright OpenAI")
        (ex / "sources.toml").write_text('[[file]]\ncomponent = "codex"\nversion = "0.1"\nlicense = "Apache-2.0"\npath = "NOTICE"\nurl = "https://example.com/NOTICE"\n')
        inv = Inventory(out, "test")
        scan_extra(inv, ex)
        c = inv.components[("upstream", "codex", "0.1")]
        eq((c["license"], [Path(f).name for f in c["files"]], c["urls"]), ("Apache-2.0", ["NOTICE"], ["https://example.com/NOTICE"]), "extra")

        # cargo：只算普通依赖，dev 依赖和只在构建时用的不算；license 为空时看 license_file
        crate_dir = tmp / "registry"
        for n in ("dep", "devdep", "builddep", "lf"):
            (crate_dir / n).mkdir(parents=True)
            (crate_dir / n / "Cargo.toml").write_text("")
        (crate_dir / "dep" / "LICENSE-MIT").write_text(MIT_TEXT)
        (crate_dir / "lf" / "COPYING").write_text(ISC_TEXT)

        def cp(n, lic, lf=None, ws=False):
            return {"id": n, "name": n, "version": "1.0.0", "license": lic, "license_file": lf,
                    "manifest_path": str((tmp / "ws" if ws else crate_dir / n) / "Cargo.toml")}

        meta = {
            "packages": [cp("app", "UNLICENSED", ws=True), cp("dep", "MIT/Apache-2.0"), cp("devdep", "AGPL-3.0"),
                         cp("builddep", "GPL-3.0"), cp("lf", None, "COPYING")],
            "workspace_members": ["app"],
            "resolve": {"nodes": [
                {"id": "app", "deps": [{"pkg": "dep", "dep_kinds": [{"kind": None}]}, {"pkg": "devdep", "dep_kinds": [{"kind": "dev"}]},
                                       {"pkg": "builddep", "dep_kinds": [{"kind": "build"}]}]},
                {"id": "dep", "deps": [{"pkg": "lf", "dep_kinds": [{"kind": None}]}]},
                {"id": "devdep", "deps": []}, {"id": "builddep", "deps": []}, {"id": "lf", "deps": []},
            ]},
        }
        mj = tmp / "meta.json"
        mj.write_text(json.dumps(meta))
        inv = Inventory(out, "app")
        scan_cargo(inv, ["app"], metadata_json=mj)
        got = {c["name"]: c for c in inv.components.values()}
        eq(sorted(got), ["dep", "lf"], "cargo 只算普通依赖")
        eq(got["dep"]["license"], "MIT OR Apache-2.0", "cargo 旧写法")
        eq(got["lf"]["license"], "ISC", "license_file")

        # 检查：例外、未知、禁止、清单核对
        inv = Inventory(out, "agents/demo:1.0")
        scan_npm(inv, nm)
        doc = inv.write()
        manifest = {"agent": {"id": "demo", "license": "LicenseRef-Vendor-Commercial"}, "install": {"npm": ["@vendor/sdk@1.2.0", "a@1.0.0"]}}
        errors, warnings, summary = check(doc, pol, manifest)
        joined = "\n".join(errors)
        eq("npm e@1.0.0" in joined and "禁止" in joined, True, "AGPL 被拦")
        eq("@vendor/sdk" in joined, False, "登记过的专有包不报错")
        eq(len(errors), 1, "只有 AGPL 一个问题：%s" % errors)
        eq("登记过的例外" in summary, True, "汇总里列出例外")
        bad = dict(manifest, agent={"id": "demo", "license": "MIT"})
        errors, _, _ = check(doc, pol, bad)
        eq(any("agent.license" in e for e in errors), True, "清单的许可证和上游对不上")
        wrong_version = dict(manifest, install={"npm": ["@vendor/sdk@1.3.0"]})
        errors, _, _ = check(doc, pol, wrong_version)
        eq(any("锁定" in e for e in errors), True, "版本和清单对不上")
        # 上游改了许可证：例外不再匹配
        doc2 = json.loads(json.dumps(doc))
        for c in doc2["components"]:
            if c["name"] == "@vendor/sdk":
                c["declared"] = "SEE LICENSE IN TERMS.md"
        errors, _, _ = check(doc2, pol, manifest)
        eq(any("@vendor/sdk" in e and "认不出" in e for e in errors), True, "例外按声明匹配，声明变了要重新登记")
        eq(any("没找到" in e for e in errors), True, "登记了但没用上的例外要报")
        # 原文的哈希：写了就要对上
        sha = hashlib.sha256(PROPRIETARY_TEXT.encode()).hexdigest()
        pinned = Policy(tomllib.loads(TEST_POLICY.replace('reason = "专有', 'text_sha256 = "%s"\nreason = "专有' % sha)))
        errors, _, _ = check(doc, pinned, manifest)
        eq(len(errors), 1, "原文哈希对得上：%s" % errors)
        pinned = Policy(tomllib.loads(TEST_POLICY.replace('reason = "专有', 'text_sha256 = "%s"\nreason = "专有' % ("0" * 64))))
        errors, _, _ = check(doc, pinned, manifest)
        eq(any("@vendor/sdk" in e and "认不出" in e for e in errors), True, "原文改了登记失效")
        # extra 原文按哪个版本核对的
        stale_doc = json.loads(json.dumps(doc))
        stale_doc["components"].append({"ecosystem": "upstream", "name": "bun", "version": "1", "license": "MIT", "declared": "MIT",
                                         "files": ["x"], "root_level": False, "applies_to": ["npm:@vendor/sdk@9.9.9"], "notices_dir": "demo"})
        errors, _, _ = check(stale_doc, pol, manifest)
        eq(any("notices/demo" in e for e in errors), True, "extra 原文的版本对不上要报")
        # Debian：只拦禁止的
        deb_doc = {"subject": "x", "components": [
            {"ecosystem": "deb", "name": "bash", "version": "5", "license": None, "declared": "GPL-3+, BSD-4-clause", "files": [], "root_level": False},
            {"ecosystem": "deb", "name": "bad", "version": "1", "license": None, "declared": "AGPL-3.0", "files": [], "root_level": False},
        ]}
        errors, _, _ = check(deb_doc, pol)
        eq(errors == ["deb bad@1：许可证 AGPL-3.0 在禁止名单里"], True, "Debian 只拦禁止的：%s" % errors)

    # 仓库里的策略文件能加载，例外都写了理由
    real = Path(__file__).with_name("policy.toml")
    if real.is_file():
        Policy.load(real)

    if failures:
        for f in failures:
            print("FAIL", f)
        return 1
    print("licenses.py self-test: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
